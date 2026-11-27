import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GetScript(unittest.TestCase):
    """get.sh: download the sources of a release, run its install.sh --prebuilt against that same release, and add
    the openset-llm command. A failed install must leave the previous scripts and command as they were."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.tools = self.work / 'tools'
        self.tools.mkdir()
        for name in ('dirname', 'grep', 'cut', 'sed', 'awk', 'cat', 'mkdir', 'mv', 'rm', 'tar', 'gzip', 'mktemp',
                     'chmod', 'bash', 'sh', 'env'):
            executable = shutil.which(name)
            if executable:
                (self.tools / name).symlink_to(executable)
        self.command(self.tools / 'python3', '#!/bin/sh\nexit 0\n')
        self.command(self.tools / 'uname', '#!/bin/sh\ncase $1 in -s) echo "${FAKE_OS:-Linux}" ;; -m) echo "${FAKE_ARCH:-x86_64}" ;; esac\n')
        self.command(self.tools / 'getconf', '#!/bin/sh\necho "glibc ${FAKE_GLIBC:-2.39}"\n')
        # -I ... -w: the "latest release" redirect; otherwise: the source tarball on stdout
        self.command(self.tools / 'curl', '#!/bin/sh\n'
            'printf \'%s\\n\' "$*" >> "$CURL_LOG"\n'
            'case " $* " in\n'
            '  *" -w "*) printf \'%s\' "https://github.com/opensetlabs/openset-llm/releases/tag/${LATEST:-v9.8.7}" ;;\n'
            '  *) [ -f "$SOURCE" ] || exit 22; cat "$SOURCE" ;;\n'
            'esac\n')
        self.app = self.work / 'share/openset-llm'
        self.bindir = self.work / 'bin'
        self.source = self.work / 'source.tar.gz'
        self.env = {'HOME': str(self.work), 'PATH': str(self.tools), 'OPENSET_LLM_APP': str(self.app),
                    'OPENSET_LLM_BIN_DIR': str(self.bindir), 'SOURCE': str(self.source),
                    'CURL_LOG': str(self.work / 'curl.log'), 'INSTALL_LOG': str(self.work / 'install.log')}

    def command(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def release(self, install_rc=0, prebuilt=True, marker='new'):
        files = {
            'install.sh': '#!/bin/bash\n# --prebuilt\n' if prebuilt else '#!/bin/bash\n',
            'serve': f'#!/bin/sh\necho "serve {marker} $*"\n',
            'start': f'#!/bin/sh\necho "start {marker} $*"\n',
        }
        files['install.sh'] += ('printf \'%s|%s\\n\' "$*" "$OPENSET_LLM_RELEASE_URL" >> "$INSTALL_LOG"\n'
                                'echo "Start it:           from-the-staging-folder/serve"\n'
                                f'exit {install_rc}\n')
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as tar:
            for name, text in files.items():
                data = text.encode()
                entry = tarfile.TarInfo(f'openset-llm-9.8.7/{name}')
                entry.mode = 0o755
                entry.size = len(data)
                tar.addfile(entry, io.BytesIO(data))
        self.source.write_bytes(stream.getvalue())

    def get(self, **extra):
        with open(ROOT / 'get.sh') as script:   # piped, the way users run it
            return subprocess.run(['/bin/bash'], stdin=script, env={**self.env, **extra},
                                  text=True, capture_output=True, timeout=20)

    def launcher(self, *args):
        return subprocess.run([str(self.bindir / 'openset-llm'), *args], env=self.env, text=True, capture_output=True)

    def test_installs_the_latest_release_and_the_command(self):
        self.release()
        result = self.get()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / '.version').read_text().strip(), 'v9.8.7')
        self.assertNotIn('from-the-staging-folder', result.stdout)   # install.sh's own hint names a temporary folder
        self.assertIn('Start it:', result.stdout)
        # install.sh ran with --prebuilt, against the assets of that same release
        self.assertEqual((self.work / 'install.log').read_text().strip(),
                         '--prebuilt|https://github.com/opensetlabs/openset-llm/releases/download/v9.8.7')
        self.assertIn('archive/refs/tags/v9.8.7.tar.gz', (self.work / 'curl.log').read_text())
        self.assertEqual(self.launcher().stdout.strip(), 'start new')
        self.assertEqual(self.launcher('--port', '9000').stdout.strip(), 'start new --port 9000')
        self.assertEqual(self.launcher('start', '--port', '9000').stdout.strip(), 'start new --port 9000')
        self.assertEqual(self.launcher('serve', '--no-spec').stdout.strip(), 'serve new --no-spec')
        self.assertEqual(self.launcher('version').stdout.strip(), 'v9.8.7')
        self.assertEqual([p.name for p in self.app.parent.iterdir()], ['openset-llm'])   # no staging left behind

    def test_a_named_version_is_used_without_asking_for_the_latest(self):
        self.release()
        result = self.get(OPENSET_LLM_VERSION='v1.2.3')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / '.version').read_text().strip(), 'v1.2.3')
        self.assertNotIn(' -w ', (self.work / 'curl.log').read_text())
        self.assertIn('releases/download/v1.2.3', (self.work / 'install.log').read_text())

    def test_failed_install_keeps_the_previous_version(self):
        self.release(marker='old')
        self.assertEqual(self.get().returncode, 0)
        self.release(install_rc=7, marker='broken')
        result = self.get()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('did not finish', result.stderr)
        self.assertEqual(self.launcher().stdout.strip(), 'start old')
        self.assertEqual([p.name for p in self.app.parent.iterdir()], ['openset-llm'])

    def test_update_replaces_the_previous_version(self):
        self.release(marker='old')
        self.assertEqual(self.get().returncode, 0)
        self.release(marker='newer')
        self.assertEqual(self.get().returncode, 0)
        self.assertEqual(self.launcher().stdout.strip(), 'start newer')
        self.assertEqual([p.name for p in self.app.parent.iterdir()], ['openset-llm'])

    def test_release_without_a_prebuilt_engine_is_refused(self):
        self.release(prebuilt=False)
        result = self.get()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no prebuilt engine', result.stderr)
        self.assertFalse(self.app.exists())
        self.assertFalse((self.work / 'install.log').exists())

    def test_unsupported_machines_are_told_to_build_from_source(self):
        self.release()
        for extra, message in (({'FAKE_ARCH': 'aarch64'}, 'x86-64 only'), ({'FAKE_OS': 'Darwin'}, 'for Linux'),
                               ({'FAKE_GLIBC': '2.31'}, 'older than'), ({'FAKE_GLIBC': '2.9'}, 'older than')):
            with self.subTest(extra=extra):
                result = self.get(**extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertIn('git clone', result.stderr)
                self.assertFalse(self.app.exists())
        for glibc in ('2.35', '2.36', '2.41'):
            with self.subTest(glibc=glibc):
                self.assertEqual(self.get(FAKE_GLIBC=glibc).returncode, 0)

    def test_unexpected_release_name_is_refused(self):
        self.release()
        result = self.get(LATEST='login?return_to=x')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unexpected release name', result.stderr)
        self.assertFalse(self.app.exists())


if __name__ == '__main__':
    unittest.main()
