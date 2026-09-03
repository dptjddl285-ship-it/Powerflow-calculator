# -*- coding: utf-8 -*-
import unittest
import json
from unittest.mock import patch, MagicMock
import cv2
import numpy as np
from core.bus_number_linker import link_and_validate_bus_numbers
from review.vision_adapter import build_graph_document
from review.graph_document import ReviewState

class TestBusNumberLinker(unittest.TestCase):
    def setUp(self):
        img = np.zeros((600, 800, 3), dtype=np.uint8)
        _, enc = cv2.imencode('.jpg', img)
        self.dummy_bytes = enc.tobytes()
        
    def test_duplicate_bus_numbers_marked_uncertain(self):
        nodes = [
            {"id": "bus_0", "class": "bus", "bbox": [100, 100, 50, 10]},
            {"id": "bus_1", "class": "bus", "bbox": [200, 200, 50, 10]},
            {"id": "bus_2", "class": "bus", "bbox": [300, 300, 50, 10]}
        ]
        mock_reply = '{"bus_0": 12, "bus_1": 12, "bus_2": 5}'
        mock_body = json.dumps({
            "candidates": [{
                "content": {
                    "parts": [{"text": mock_reply}]
                }
            }]
        }).encode('utf-8')
        
        with patch('urllib.request.urlopen') as mock_urlopen:
            mock_resp = MagicMock()
            mock_resp.read.return_value = mock_body
            mock_urlopen.return_value.__enter__.return_value = mock_resp
            
            validated_nodes, report = link_and_validate_bus_numbers(self.dummy_bytes, nodes, api_key="dummy_key")
            
            self.assertEqual(report['total_buses'], 3)
            self.assertEqual(report['verified_count'], 1)
            self.assertEqual(report['uncertain_count'], 2)
            self.assertIn(12, report['duplicates'])
            
            # bus_0 & bus_1 duplicate -> UNCERTAIN
            self.assertEqual(validated_nodes[0]['bus_number_status'], 'UNCERTAIN')
            self.assertIn('DUPLICATE_BUS_NUMBER_12', validated_nodes[0]['bus_number_reasons'])
            
            # bus_2 unique -> VERIFIED
            self.assertEqual(validated_nodes[2]['bus_number_status'], 'VERIFIED')
            self.assertEqual(validated_nodes[2]['bus_number'], 5)

    def test_graph_document_non_destructive_state(self):
        raw_result = {
            "nodes": [
                {
                    "id": "bus_rescued",
                    "class": "bus",
                    "bbox": [100, 100, 50, 10],
                    "source": "cv_bus_rescue",
                    "bus_number": 7,
                    "bus_number_status": "VERIFIED"
                },
                {
                    "id": "bus_duplicate",
                    "class": "bus",
                    "bbox": [200, 200, 50, 10],
                    "source": "yolo_detector",
                    "bus_number": 12,
                    "bus_number_status": "UNCERTAIN",
                    "bus_number_reasons": ["DUPLICATE_BUS_NUMBER_12"]
                }
            ],
            "lines": []
        }
        doc = build_graph_document(raw_result, image_bytes=self.dummy_bytes)
        node0 = doc.nodes[0]
        # Structural review state must remain AUTO_RESCUED, not overwritten to ACCEPTED!
        self.assertEqual(node0.review_state, ReviewState.AUTO_RESCUED)
        self.assertEqual(node0.display_bus_no, 7)
        self.assertEqual(node0.parameters.get('bus_number_status'), 'VERIFIED')
        
        node1 = doc.nodes[1]
        # bus_duplicate has UNCERTAIN status -> elevated to NEEDS_REVIEW
        self.assertEqual(node1.review_state, ReviewState.NEEDS_REVIEW)
        self.assertEqual(node1.display_bus_no, 12)
        self.assertEqual(node1.parameters.get('bus_number_status'), 'UNCERTAIN')

if __name__ == '__main__':
    unittest.main()
