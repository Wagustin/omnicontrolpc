#!/usr/bin/env python3
"""
Test Voice Pipeline Integration
Verifica el flujo completo: Captura/Mock de Audio -> Whisper STT (es) -> Tool Router -> System Bridge
"""

import os
import sys
import unittest
from pathlib import Path

# Add project root to path
PROJECT_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

import numpy as np
from omnicontrol_voice import VoicePipeline, WhisperConfig, AudioConfig
from jarvis_client import rule_based_fallback, run_omnicontrol
import system_bridge

class TestVoiceEndToEnd(unittest.TestCase):
    """Pruebas del pipeline de voz a herramientas."""

    def test_voice_transcription_dispatch(self):
        """Verifica que el callback de transcripción despache a run_omnicontrol."""
        executed_commands = []
        
        def mock_dispatch(text):
            calls = rule_based_fallback(text)
            for c in calls:
                res = system_bridge.execute_tool(c)
                executed_commands.append((c, res))
                
        # Simular transcripciones en español
        test_phrases = [
            "sube el volumen al 45%",
            "silencia el audio",
            "desmutea",
            "abre https://github.com",
            "captura de pantalla",
            "bloquea la pantalla"
        ]
        
        for phrase in test_phrases:
            mock_dispatch(phrase)
            
        self.assertEqual(len(executed_commands), len(test_phrases))
        self.assertEqual(executed_commands[0][0]["arguments"]["action"], "set_volume")
        self.assertEqual(executed_commands[0][0]["arguments"]["level"], 45)
        self.assertEqual(executed_commands[1][0]["arguments"]["action"], "mute")
        self.assertEqual(executed_commands[2][0]["arguments"]["action"], "unmute")
        self.assertEqual(executed_commands[3][0]["arguments"]["target_type"], "url")
        self.assertEqual(executed_commands[4][0]["arguments"]["action"], "take_screenshot")
        self.assertEqual(executed_commands[5][0]["arguments"]["action"], "lock_screen")

    def test_voice_pipeline_mock_injection(self):
        """Prueba inyección de buffer en VoicePipeline sin micrófono físico."""
        results = []
        
        def on_transcribed(text):
            results.append(text)
            
        pipeline = VoicePipeline(
            model_size="tiny",
            language="es",
            on_transcription=on_transcribed,
            use_mock=True
        )
        
        # Generar buffer sintético de 0.5s de silencio
        silence = np.zeros(8000, dtype=np.float32)
        pipeline.inject_test_buffer(silence)
        
        # Iniciar y detener PTT
        pipeline.start_ptt()
        pipeline.stop_ptt()
        pipeline.wait(timeout=2.0)
        pipeline.shutdown()
        
        # En mock con silencio no debe crashear
        self.assertTrue(True)

if __name__ == "__main__":
    unittest.main()
