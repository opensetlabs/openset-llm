import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

MODEL_FILE = "Ternary-Bonsai-2-27B-PTQ1_0.gguf"
# what a model download starts with: the magic, the little-endian header version, then anything
GGUF_STUB = b"GGUF" + (3).to_bytes(4, "little") + b"\x00stub weights"


class InstallRegression(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.prefix = self.work / "installation"
        self.tools = self.work / "tools"
        self.tools.mkdir()
        (self.prefix / "bin").mkdir(parents=True)
        (self.prefix / "models").mkdir()
        self.command(self.prefix / "bin/llama-server", "#!/bin/sh\nexit 0\n")
        for name in ("dirname", "uname", "grep", "cut", "sed", "awk", "cat", "mkdir", "id",
                     "mv", "rm", "touch", "tar", "gzip", "head", "mktemp", "basename", "flock"):
            executable = shutil.which(name)
            if executable:
                (self.tools / name).symlink_to(executable)
        self.command(self.tools / "df", "#!/bin/sh\nprintf 'Filesystem 1024-blocks Used Available Capacity Mounted\nfixture 999999999 0 999999999 0%% /\n'\n")
        self.command(self.tools / "du", "#!/bin/sh\nprintf '0 fixture\n'\n")
        self.command(self.tools / "python3", "#!/bin/sh\nexit 0\n")
        self.command(self.tools / "curl", "#!/bin/sh\nprintf download >> \"$DOWNLOAD_LOG\"\n"
            "while [ \"$#\" -gt 0 ]; do if [ \"$1\" = -o ]; then shift; cat \"$DOWNLOAD_BODY\" > \"$1\"; fi; shift; done\n")
        self.env = {**os.environ, "OPENSET_LLM_HOME": str(self.prefix),
                    "PATH": str(self.tools), "DOWNLOAD_LOG": str(self.work / "downloads"),
                    "DOWNLOAD_BODY": str(self.work / "body")}
        self.env.pop("OPENSET_LLM_BIN_URL", None)
        self.env.pop("HF_TOKEN", None)

    def command(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def body(self, content):
        (self.work / "body").write_bytes(content)

    def install(self, *args):
        return subprocess.run(["/bin/bash", str(ROOT / "install.sh"), *args],
                              env=self.env, text=True, capture_output=True, timeout=15)

    def test_non_gguf_body_is_not_published(self):
        self.body(b"<html><body>503 Service Unavailable</body></html>")
        result = self.install("--model-only", "--no-mtp")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not a GGUF model file", result.stderr)
        self.assertIn(MODEL_FILE, result.stderr)
        self.assertFalse((self.prefix / "models/model.gguf").exists())
        self.assertFalse((self.prefix / "models/base.gguf.part").exists())

    def test_gguf_body_is_published(self):
        self.body(GGUF_STUB)
        result = self.install("--model-only", "--no-mtp")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.prefix / "models/model.gguf").read_bytes(), GGUF_STUB)
        self.assertFalse((self.prefix / "models/base.gguf.part").exists())

    def test_existing_model_is_left_alone(self):
        (self.prefix / "models/model.gguf").write_bytes(b"already here")
        self.body(b"<html><body>never fetched</body></html>")
        result = self.install("--model-only", "--no-mtp")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.prefix / "models/model.gguf").read_bytes(), b"already here")
        self.assertFalse((self.work / "downloads").exists())


if __name__ == "__main__":
    unittest.main()
