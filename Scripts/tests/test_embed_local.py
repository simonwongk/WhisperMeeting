"""F316 — the parts of embed_local.py that need no model."""
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("embed_local", os.path.join(HERE, "..", "embed_local.py"))
embed_local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(embed_local)


class EmbedLocalTests(unittest.TestCase):
    def test_e5_prefixes_follow_the_kind(self):
        # e5 is trained with these prefixes; a passage embedded as a query ranks measurably worse.
        self.assertEqual(embed_local.e5_inputs("query", ["a"]), ["query: a"])
        self.assertEqual(embed_local.e5_inputs("passage", ["a", "b"]), ["passage: a", "passage: b"])
        self.assertEqual(embed_local.e5_inputs("anything else", ["a"]), ["passage: a"])

    def test_batches_cover_every_index_once_and_group_by_length(self):
        texts = ["x" * n for n in (50, 1, 40, 2, 3)]
        groups = embed_local.batches(texts, 2)
        self.assertEqual(sorted(i for g in groups for i in g), [0, 1, 2, 3, 4])
        self.assertEqual(groups[0], [1, 3])          # the two shortest pad together
        self.assertEqual(groups[-1], [0])

    def test_it_never_reaches_for_the_network(self):
        with open(os.path.join(HERE, "..", "embed_local.py"), encoding="utf-8") as handle:
            code = "\n".join(line for line in handle.read().split("\n") if not line.lstrip().startswith("#"))
        body = code.split('"""', 2)[2]
        self.assertNotIn("huggingface_hub", body)
        self.assertNotIn("snapshot_download", body)


if __name__ == "__main__":
    unittest.main()
