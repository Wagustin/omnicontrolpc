#!/usr/bin/env python3
"""
OmniControl PC — Local Voice Capture & Speech-to-Text Pipeline
Push-to-Talk + VAD audio capture with faster-whisper (int8, tiny/base, Spanish)
Ultralow latency target: <250ms end-to-end
"""

import os
import sys
import threading
import time
import wave
import math
import struct
from pathlib import Path
from typing import Optional, Callable, Union, Generator
from dataclasses import dataclass
from collections import deque

import numpy as np

# Optional imports with graceful degradation
_sd = None
_sf = None
_WhisperModel = None

try:
    import sounddevice as _sd
    SOUNDDEVICE_AVAILABLE = True
except (ImportError, OSError) as e:
    SOUNDDEVICE_AVAILABLE = False
    _SD_IMPORT_ERROR = e

try:
    import soundfile as _sf
    SOUNDFILE_AVAILABLE = True
except ImportError:
    SOUNDFILE_AVAILABLE = False

try:
    from faster_whisper import WhisperModel as _WhisperModel
    FASTER_WHISPER_AVAILABLE = True
except ImportError:
    FASTER_WHISPER_AVAILABLE = False

# Aliases for internal use
sd = _sd
sf = _sf
WhisperModel = _WhisperModel


# ════════════════════════════════════════════════════════════════════════════
# Configuration
# ════════════════════════════════════════════════════════════════════════════

@dataclass
class AudioConfig:
    sample_rate: int = 16000
    channels: int = 1
    dtype: str = "int16"
    chunk_ms: int = 30            # Frame size for VAD
    vad_threshold: float = 0.02   # RMS threshold for voice detection
    vad_silence_ms: int = 800     # Silence duration to auto-stop
    max_record_sec: int = 30      # Hard cap
    pre_buffer_sec: float = 0.3   # Pre-roll buffer before PTT press


@dataclass
class WhisperConfig:
    model_size: str = "tiny"      # "tiny" or "base"
    device: str = "cpu"
    compute_type: str = "int8"    # Quantization for speed
    language: str = "es"          # Spanish
    beam_size: int = 1            # Greedy for speed
    vad_filter: bool = True       # Built-in VAD filter
    vad_parameters: Optional[dict] = None

    def __post_init__(self):
        if self.vad_parameters is None:
            self.vad_parameters = dict(min_silence_duration_ms=500)


# ════════════════════════════════════════════════════════════════════════════
# Audio Feedback (clicks/beeps)
# ════════════════════════════════════════════════════════════════════════════

def generate_tone(freq: float, duration_ms: int, sample_rate: int = 16000, volume: float = 0.3) -> np.ndarray:
    """Generate a sine wave tone."""
    t = np.linspace(0, duration_ms / 1000, int(sample_rate * duration_ms / 1000), False)
    wave = np.sin(2 * np.pi * freq * t) * volume
    return (wave * 32767).astype(np.int16)


def play_start_tone(config: AudioConfig):
    """Play a subtle 'start listening' tone (ascending)."""
    if not SOUNDDEVICE_AVAILABLE:
        return
    tone1 = generate_tone(880, 60, config.sample_rate, 0.25)
    tone2 = generate_tone(1100, 60, config.sample_rate, 0.25)
    combined = np.concatenate([tone1, tone2])
    try:
        sd.play(combined, config.sample_rate, blocking=False)
    except Exception:
        pass


def play_stop_tone(config: AudioConfig):
    """Play a subtle 'stop listening' tone (descending)."""
    if not SOUNDDEVICE_AVAILABLE:
        return
    tone1 = generate_tone(1100, 60, config.sample_rate, 0.25)
    tone2 = generate_tone(880, 60, config.sample_rate, 0.25)
    combined = np.concatenate([tone1, tone2])
    try:
        sd.play(combined, config.sample_rate, blocking=False)
    except Exception:
        pass


def play_error_tone(config: AudioConfig):
    """Play an error tone."""
    if not SOUNDDEVICE_AVAILABLE:
        return
    tone = generate_tone(440, 200, config.sample_rate, 0.3)
    try:
        sd.play(tone, config.sample_rate, blocking=False)
    except Exception:
        pass


# ════════════════════════════════════════════════════════════════════════════
# Mock Audio Source (for headless/testing)
# ════════════════════════════════════════════════════════════════════════════

class MockAudioSource:
    """
    Inject audio from file or synthetic buffer for testing without microphone.
    Supports: wav, ogg, mp3 (via soundfile), or raw numpy buffers.
    """
    def __init__(self, config: AudioConfig):
        self.config = config
        self._buffer: Optional[np.ndarray] = None
        self._position = 0
        self._lock = threading.Lock()

    def load_file(self, path: Union[str, Path]) -> bool:
        """Load audio file (wav/ogg/mp3) and resample to config sample_rate."""
        if not SOUNDFILE_AVAILABLE:
            print("[MockAudio] soundfile not available, cannot load audio files")
            return False
        try:
            data, sr = sf.read(path, dtype="int16")
            if data.ndim > 1:
                data = data.mean(axis=1).astype(np.int16)  # Mono
            if sr != self.config.sample_rate:
                # Simple linear resample
                ratio = self.config.sample_rate / sr
                new_len = int(len(data) * ratio)
                indices = np.linspace(0, len(data) - 1, new_len)
                data = np.interp(indices, np.arange(len(data)), data).astype(np.int16)
            with self._lock:
                self._buffer = data
                self._position = 0
            print(f"[MockAudio] Loaded {path}: {len(data)/self.config.sample_rate:.2f}s")
            return True
        except Exception as e:
            print(f"[MockAudio] Failed to load {path}: {e}")
            return False

    def load_buffer(self, buffer: np.ndarray):
        """Inject raw int16 numpy buffer."""
        with self._lock:
            self._buffer = buffer.astype(np.int16)
            self._position = 0

    def read(self, frames: int) -> np.ndarray:
        """Read frames from buffer, zero-pad at end."""
        with self._lock:
            if self._buffer is None:
                return np.zeros(frames, dtype=np.int16)
            end = min(self._position + frames, len(self._buffer))
            chunk = self._buffer[self._position:end]
            self._position = end
            if len(chunk) < frames:
                chunk = np.pad(chunk, (0, frames - len(chunk)), mode="constant")
            return chunk

    def reset(self):
        with self._lock:
            self._position = 0

    @property
    def is_exhausted(self) -> bool:
        with self._lock:
            return self._buffer is not None and self._position >= len(self._buffer)


# ════════════════════════════════════════════════════════════════════════════
# Voice Activity Detection
# ════════════════════════════════════════════════════════════════════════════

class VoiceActivityDetector:
    """Simple RMS-based VAD with configurable threshold and silence timeout."""
    def __init__(self, config: AudioConfig):
        self.config = config
        self.frame_samples = int(config.sample_rate * config.chunk_ms / 1000)
        self.silence_frames = int(config.vad_silence_ms / config.chunk_ms)
        self._silence_count = 0
        self._triggered = False

    def process(self, audio_chunk: np.ndarray) -> bool:
        """
        Returns True if voice is active in this chunk.
        Updates internal state for silence detection.
        """
        # RMS energy
        rms = np.sqrt(np.mean(audio_chunk.astype(np.float32) ** 2)) / 32768.0
        is_voice = rms > self.config.vad_threshold

        if is_voice:
            self._silence_count = 0
            self._triggered = True
        elif self._triggered:
            self._silence_count += 1

        return is_voice

    def should_stop(self) -> bool:
        """True if silence timeout reached after voice was detected."""
        return self._triggered and self._silence_count >= self.silence_frames

    def reset(self):
        self._silence_count = 0
        self._triggered = False


# ════════════════════════════════════════════════════════════════════════════
# Whisper Transcriber
# ════════════════════════════════════════════════════════════════════════════

class WhisperTranscriber:
    """Local Whisper transcription using faster-whisper (CTranslate2)."""
    _instance: Optional["WhisperTranscriber"] = None
    _lock = threading.Lock()

    def __init__(self, config: WhisperConfig):
        if not FASTER_WHISPER_AVAILABLE:
            raise RuntimeError("faster-whisper not installed. Run: uv pip install faster-whisper")
        self.config = config
        self._model: Optional[WhisperModel] = None
        self._load_model()

    @classmethod
    def get_instance(cls, config: Optional[WhisperConfig] = None) -> "WhisperTranscriber":
        """Singleton pattern for model reuse."""
        with cls._lock:
            if cls._instance is None:
                if config is None:
                    config = WhisperConfig()
                cls._instance = cls(config)
            return cls._instance

    def _load_model(self):
        print(f"[Whisper] Loading {self.config.model_size} ({self.config.compute_type}) on {self.config.device}...")
        start = time.perf_counter()
        self._model = WhisperModel(
            self.config.model_size,
            device=self.config.device,
            compute_type=self.config.compute_type,
        )
        elapsed = (time.perf_counter() - start) * 1000
        print(f"[Whisper] Model loaded in {elapsed:.0f}ms")

    def transcribe(self, audio: np.ndarray) -> str:
        """
        Transcribe int16 numpy audio array to text.
        Returns empty string on failure.
        """
        if self._model is None:
            return ""

        # Convert int16 to float32 [-1, 1]
        audio_float = audio.astype(np.float32) / 32768.0

        try:
            segments, info = self._model.transcribe(
                audio_float,
                language=self.config.language,
                beam_size=self.config.beam_size,
                vad_filter=self.config.vad_filter,
                vad_parameters=self.config.vad_parameters,
            )
            text = " ".join(seg.text for seg in segments).strip()
            return text
        except Exception as e:
            print(f"[Whisper] Transcription error: {e}")
            return ""


# ════════════════════════════════════════════════════════════════════════════
# Push-to-Talk Capture Engine
# ════════════════════════════════════════════════════════════════════════════

class PushToTalkCapture:
    """
    Push-to-Talk audio capture with VAD fallback.
    - Hold hotkey: record while pressed, stop on release
    - Toggle hotkey: press to start, press again to stop
    - VAD auto-stop: stops after configurable silence
    - Pre-buffer: captures audio before PTT press
    """

    def __init__(
        self,
        audio_config: Optional[AudioConfig] = None,
        whisper_config: Optional[WhisperConfig] = None,
        on_transcription: Optional[Callable[[str], None]] = None,
        use_mock: bool = False,
        mock_source: Optional[MockAudioSource] = None,
    ):
        self.audio_config = audio_config or AudioConfig()
        self.whisper_config = whisper_config or WhisperConfig()
        self.on_transcription = on_transcription
        self.use_mock = use_mock or not SOUNDDEVICE_AVAILABLE

        # State
        self._recording = False
        self._ptt_held = False
        self._toggle_mode = False
        self._stream = None
        self._capture_thread: Optional[threading.Thread] = None
        self._audio_queue: deque = deque()
        self._pre_buffer: deque = deque(maxlen=int(self.audio_config.sample_rate * self.audio_config.pre_buffer_sec / self.audio_config.chunk_ms))
        self._vad = VoiceActivityDetector(self.audio_config)
        self._transcriber = WhisperTranscriber.get_instance(self.whisper_config)

        # Mock support
        self._mock_source = mock_source or MockAudioSource(self.audio_config)

        # Callbacks
        self._on_start: Optional[Callable] = None
        self._on_stop: Optional[Callable] = None

    def set_callbacks(self, on_start: Callable = None, on_stop: Callable = None):
        self._on_start = on_start
        self._on_stop = on_stop

    def load_mock_audio(self, path: Union[str, Path]) -> bool:
        """Load audio file for mock/testing mode."""
        return self._mock_source.load_file(path)

    def inject_mock_buffer(self, buffer: np.ndarray):
        """Inject raw audio buffer for testing."""
        self._mock_source.load_buffer(buffer)

    def _capture_loop(self):
        """Main capture loop running in background thread."""
        frame_samples = int(self.audio_config.sample_rate * self.audio_config.chunk_ms / 1000)

        while self._recording:
            try:
                if self.use_mock:
                    chunk = self._mock_source.read(frame_samples)
                    if self._mock_source.is_exhausted:
                        break
                    time.sleep(self.audio_config.chunk_ms / 1000)  # Simulate real-time
                else:
                    chunk, overflow = self._stream.read(frame_samples)
                    if overflow:
                        print("[PTT] Input overflow")
                    chunk = chunk.flatten()

                # Pre-buffer fill when not yet triggered
                if not self._ptt_held and not self._toggle_mode:
                    self._pre_buffer.append(chunk.copy())
                    continue

                # VAD processing
                is_voice = self._vad.process(chunk)
                self._audio_queue.append(chunk)

                # Auto-stop on silence (VAD fallback)
                if self._vad.should_stop():
                    print("[PTT] VAD silence timeout — auto stop")
                    break

            except Exception as e:
                print(f"[PTT] Capture error: {e}")
                break

        # In mock mode, if we still have audio in the buffer, keep processing until exhausted
        if self.use_mock and not self._mock_source.is_exhausted:
            print("[PTT] Mock mode: draining remaining audio...")
            while not self._mock_source.is_exhausted:
                chunk = self._mock_source.read(frame_samples)
                is_voice = self._vad.process(chunk)
                self._audio_queue.append(chunk)
                if self._vad.should_stop():
                    print("[PTT] VAD silence timeout — auto stop")
                    break

        self._finish_recording()

    def _finish_recording(self):
        """Finalize recording and transcribe."""
        self._recording = False
        play_stop_tone(self.audio_config)

        if self._on_stop:
            try:
                self._on_stop()
            except Exception:
                pass

        # Concatenate all captured audio
        if not self._audio_queue:
            print("[PTT] No audio captured")
            return

        # Prepend pre-buffer
        all_chunks = list(self._pre_buffer) + list(self._audio_queue)
        audio_data = np.concatenate(all_chunks)

        # Trim trailing silence (rough)
        audio_data = self._trim_silence(audio_data)

        if len(audio_data) < self.audio_config.sample_rate * 0.2:  # <200ms
            print("[PTT] Audio too short, discarding")
            return

        print(f"[PTT] Transcribing {len(audio_data)/self.audio_config.sample_rate:.2f}s audio...")
        start = time.perf_counter()
        text = self._transcriber.transcribe(audio_data)
        elapsed = (time.perf_counter() - start) * 1000
        print(f"[PTT] Transcription: '{text}' ({elapsed:.0f}ms)")

        if text and self.on_transcription:
            try:
                self.on_transcription(text)
            except Exception as e:
                print(f"[PTT] Callback error: {e}")

    def _trim_silence(self, audio: np.ndarray, threshold: float = 0.01) -> np.ndarray:
        """Trim leading/trailing silence."""
        energy = np.abs(audio.astype(np.float32)) / 32768.0
        voiced = energy > threshold
        if not np.any(voiced):
            return audio
        start = np.argmax(voiced)
        end = len(voiced) - np.argmax(voiced[::-1])
        return audio[start:end]

    def start(self, toggle: bool = False):
        """Start recording (push-to-talk or toggle)."""
        if self._recording:
            return

        if not self.use_mock and not SOUNDDEVICE_AVAILABLE:
            print("[PTT] sounddevice not available — enabling mock mode")
            self.use_mock = True

        self._recording = True
        self._ptt_held = True
        self._toggle_mode = toggle
        self._vad.reset()
        self._audio_queue.clear()
        self._pre_buffer.clear()
        self._mock_source.reset()

        play_start_tone(self.audio_config)

        if self._on_start:
            try:
                self._on_start()
            except Exception:
                pass

        if not self.use_mock:
            try:
                self._stream = sd.InputStream(
                    samplerate=self.audio_config.sample_rate,
                    channels=self.audio_config.channels,
                    dtype=self.audio_config.dtype,
                    blocksize=int(self.audio_config.sample_rate * self.audio_config.chunk_ms / 1000),
                )
                self._stream.start()
            except Exception as e:
                print(f"[PTT] Failed to start audio stream: {e}")
                play_error_tone(self.audio_config)
                self._recording = False
                return

        self._capture_thread = threading.Thread(target=self._capture_loop, daemon=True)
        self._capture_thread.start()

    def stop(self):
        """Stop recording (release PTT or toggle off)."""
        if not self._recording:
            return

        self._ptt_held = False
        if not self._toggle_mode:
            # In PTT mode, stop immediately
            self._recording = False

    def toggle(self):
        """Toggle recording on/off."""
        if self._recording:
            self.stop()
        else:
            self.start(toggle=True)

    def is_recording(self) -> bool:
        return self._recording

    def wait(self, timeout: Optional[float] = None) -> bool:
        """Wait for recording to finish (for sync usage)."""
        if self._capture_thread:
            self._capture_thread.join(timeout)
            return not self._capture_thread.is_alive()
        return True

    def cleanup(self):
        """Clean up resources."""
        self._recording = False
        if self._capture_thread:
            self._capture_thread.join(timeout=1.0)
        if self._stream:
            try:
                self._stream.stop()
                self._stream.close()
            except Exception:
                pass


# ════════════════════════════════════════════════════════════════════════════
# High-Level API
# ════════════════════════════════════════════════════════════════════════════

class VoicePipeline:
    """
    High-level voice pipeline combining capture + transcription.
    Usage:
        pipeline = VoicePipeline(on_text=lambda t: print(f"User said: {t}"))
        pipeline.start_ptt()      # Hold to talk
        pipeline.toggle()         # Or toggle mode
        pipeline.load_test_audio("test.wav")  # For headless testing
    """

    def __init__(
        self,
        model_size: str = "tiny",
        language: str = "es",
        on_transcription: Optional[Callable[[str], None]] = None,
        use_mock: bool = False,
    ):
        self.audio_config = AudioConfig()
        self.whisper_config = WhisperConfig(model_size=model_size, language=language)
        self._capture = PushToTalkCapture(
            audio_config=self.audio_config,
            whisper_config=self.whisper_config,
            on_transcription=on_transcription,
            use_mock=use_mock,
        )

    def load_test_audio(self, path: Union[str, Path]) -> bool:
        """Load audio file for headless testing."""
        return self._capture.load_mock_audio(path)

    def inject_test_buffer(self, buffer: np.ndarray):
        """Inject raw audio buffer for testing."""
        self._capture.inject_mock_buffer(buffer)

    def start_ptt(self):
        """Start push-to-talk (hold to record)."""
        self._capture.start(toggle=False)

    def stop_ptt(self):
        """Stop push-to-talk."""
        self._capture.stop()

    def toggle(self):
        """Toggle recording on/off."""
        self._capture.toggle()

    def is_recording(self) -> bool:
        return self._capture.is_recording()

    def wait(self, timeout: Optional[float] = None):
        """Wait for current recording to complete."""
        self._capture.wait(timeout)

    def shutdown(self):
        self._capture.cleanup()


# ════════════════════════════════════════════════════════════════════════════
# CLI / Demo
# ════════════════════════════════════════════════════════════════════════════

def main():
    import argparse

    parser = argparse.ArgumentParser(description="OmniControl Voice Pipeline")
    parser.add_argument("--model", default="tiny", choices=["tiny", "base"], help="Whisper model size")
    parser.add_argument("--test-audio", type=str, help="Test audio file (wav/ogg/mp3) for headless mode")
    parser.add_argument("--mock", action="store_true", help="Force mock mode (no microphone)")
    parser.add_argument("--toggle", action="store_true", help="Use toggle mode instead of PTT")
    args = parser.parse_args()

    def on_text(text: str):
        print(f"\n🎤 Transcribed: {text}\n")

    pipeline = VoicePipeline(
        model_size=args.model,
        language="es",
        on_transcription=on_text,
        use_mock=args.mock or bool(args.test_audio),
    )

    if args.test_audio:
        print(f"[Demo] Loading test audio: {args.test_audio}")
        if not pipeline.load_test_audio(args.test_audio):
            print("[Demo] Failed to load test audio")
            return
        print("[Demo] Starting mock transcription...")
        pipeline.start_ptt()
        pipeline.wait(timeout=30)
        return

    print("OmniControl Voice Pipeline")
    print("  Press ENTER to start PTT (hold), 't' for toggle, 'q' to quit")
    print("  (Mock mode: " + ("ON" if pipeline._capture.use_mock else "OFF") + ")")

    try:
        while True:
            cmd = input("> ").strip().lower()
            if cmd in ("q", "quit", "exit"):
                break
            elif cmd == "t":
                pipeline.toggle()
                print(f"  Recording: {pipeline.is_recording()}")
            elif cmd == "":
                pipeline.start_ptt()
                input("  (release ENTER to stop) ")
                pipeline.stop_ptt()
                pipeline.wait()
            else:
                print("  Commands: [enter]=PTT, t=toggle, q=quit")
    except KeyboardInterrupt:
        pass
    finally:
        pipeline.shutdown()
        print("\nBye!")


if __name__ == "__main__":
    main()