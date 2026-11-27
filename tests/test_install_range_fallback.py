import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


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
        self.command(self.tools / "curl", "#!/bin/sh\nprintf download >> \"$DOWNLOAD_LOG\"\nwhile [ \"$#\" -gt 0 ]; do if [ \"$1\" = -o ]; then shift; printf fixture > \"$1\"; fi; shift; done\n")
        self.env = {**os.environ, "OPENSET_LLM_HOME": str(self.prefix),
                    "PATH": str(self.tools), "DOWNLOAD_LOG": str(self.work / "downloads")}
        self.env.pop("OPENSET_LLM_BIN_URL", None)
        self.env.pop("HF_TOKEN", None)

    def command(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def install(self, *args):
        return subprocess.run(["/bin/bash", str(ROOT / "install.sh"), *args],
                              env=self.env, text=True, capture_output=True, timeout=15)

    def test_download_restarts_when_mirror_ignores_range(self):
        contents = b"GGUF" + (3).to_bytes(4, "little") + b"resumed model body"
        ranges = []
        class Mirror(BaseHTTPRequestHandler):
            def do_GET(self):
                ranges.append(self.headers.get('Range'))
                self.send_response(200)
                self.send_header('Content-Length', str(len(contents)))
                self.end_headers()
                self.wfile.write(contents)
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Mirror)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        (self.tools / 'curl').unlink()
        (self.tools / 'curl').symlink_to(shutil.which('curl'))
        self.env['HF_ENDPOINT'] = f'http://127.0.0.1:{server.server_port}'
        self.env['NO_PROXY'] = '127.0.0.1'
        (self.prefix / 'models/base.gguf.part').write_bytes(contents[:4])
        result = self.install('--model-only', '--no-mtp')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.prefix / 'models/model.gguf').read_bytes(), contents)
        self.assertEqual(ranges, ['bytes=4-', None])


if __name__ == '__main__':
    unittest.main()
