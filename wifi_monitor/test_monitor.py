import csv
import tempfile
import unittest
from pathlib import Path

from monitor import (
    DatabaseStore,
    CsvRecorder,
    FrameError,
    SequenceTracker,
    build_report,
    code_to_volts,
    format_frame,
    parse_frame,
    render_report_page,
    xor_checksum,
)


SAMPLE_FIELDS = {
    "R": 65,
    "P": 89,
    "F": 50,
    "T": 0,
    "M": 0,
    "Z": 0,
    "A": 0,
    "E": 2,
    "D": 44,
    "S": "0012",
    "U": 0,
    "G": 1,
    "N": 7,
}


class FrameTests(unittest.TestCase):
    def test_parse_valid_frame(self):
        frame = format_frame(SAMPLE_FIELDS)
        sample = parse_frame(frame + "\r\n")
        self.assertEqual(sample["seq"], 7)
        self.assertEqual(sample["rms"], 65)
        self.assertEqual(sample["system_time"], "0012")
        self.assertEqual(sample["running"], 1)
        self.assertEqual(sample["rms_volts"], 0.8379)
        self.assertEqual(sample["peak_volts"], 1.1473)
        self.assertEqual(sample["adc_volts"], 0.5672)

    def test_adc_code_to_voltage(self):
        self.assertEqual(code_to_volts(0), 0.0)
        self.assertEqual(code_to_volts(128), 1.65)
        self.assertEqual(code_to_volts(255), 3.2871)

    def test_checksum_matches_payload(self):
        frame = format_frame(SAMPLE_FIELDS)
        payload, checksum = frame.rsplit(",C=", 1)
        self.assertEqual(int(checksum, 16), xor_checksum(payload))
        self.assertEqual(len(frame.encode("ascii")), 75)
        self.assertEqual(len((frame + "\r\n").encode("ascii")), 77)

    def test_rejects_corrupted_frame(self):
        frame = format_frame(SAMPLE_FIELDS).replace("R=065", "R=066")
        with self.assertRaises(FrameError) as context:
            parse_frame(frame)
        self.assertTrue(context.exception.checksum_error)

    def test_sequence_wrap_and_gap(self):
        tracker = SequenceTracker()
        self.assertEqual(tracker.observe(998), 0)
        self.assertEqual(tracker.observe(999), 0)
        self.assertEqual(tracker.observe(0), 0)
        self.assertEqual(tracker.observe(3), 2)


class DatabaseTests(unittest.TestCase):
    def test_session_history_and_fault_report(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            store = DatabaseStore(root / "test.db", "demo", root / "test.csv")
            try:
                for sequence, fault, second in ((0, 0, 0), (1, 1, 1), (2, 1, 2), (3, 0, 3)):
                    fields = dict(SAMPLE_FIELDS)
                    fields.update({"N": sequence, "T": fault, "M": fault, "S": f"{second:04d}"})
                    sample = parse_frame(format_frame(fields))
                    sample["pc_time"] = f"2026-06-19T12:00:0{second}+08:00"
                    sample["missing_before"] = 0
                    store.write(sample)

                sessions = store.list_sessions()
                self.assertEqual(sessions[0]["sample_count"], 4)
                history = store.history(store.session_id, 0, 10)
                self.assertEqual(len(history), 4)
                self.assertEqual(history[1]["fault_type"], 1)
                self.assertEqual(history[1]["rms_volts"], 0.8379)

                report = build_report(store, store.session_id)
                self.assertIsNotNone(report)
                self.assertEqual(report["sample_count"], 4)
                self.assertEqual(report["fault_summary"][0]["count"], 1)
                self.assertEqual(report["episodes"][0]["elapsed_seconds"], 2.0)
                report_page = render_report_page(report).decode("utf-8")
                self.assertIn("电能质量故障报告", report_page)
                self.assertIn("RMS电压(V)", report_page)
            finally:
                store.close()

    def test_csv_description_header_and_raw_frame(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.csv"
            recorder = CsvRecorder(path)
            try:
                sample = parse_frame(format_frame(SAMPLE_FIELDS))
                sample["pc_time"] = "2026-06-19T12:00:00+08:00"
                sample["missing_before"] = 0
                recorder.write(sample)
            finally:
                recorder.close()

            with path.open(newline="", encoding="utf-8-sig") as handle:
                rows = list(csv.reader(handle))
            self.assertIn("PQ=Power Quality", rows[0][-1])
            self.assertEqual(rows[1][-1], "wifi_raw_frame")
            self.assertTrue(rows[2][-1].startswith("PQ,R="))


if __name__ == "__main__":
    unittest.main()
