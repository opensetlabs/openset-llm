import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which('bash')


class MacosPaths(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.tools = self.work / 'tools'
        self.tools.mkdir()
        self.script('uname', '#!/bin/sh\n'
                             'case $1 in\n'
                             '  -s) echo Darwin ;;\n'
                             '  -m) echo "${FIXTURE_ARCH:-arm64}" ;;\n'
                             '  *) echo "Darwin 25.0.0" ;;\n'
                             'esac\n')
        self.script('sysctl', '#!/bin/sh\n'
                              '[ "$1" = -n ] || exit 1\n'
                              'case $2 in\n'
                              '  hw.memsize) echo "${FIXTURE_MEM_BYTES:-17179869184}" ;;\n'
                              '  machdep.cpu.brand_string) echo "Apple M4" ;;\n'
                              '  hw.ncpu) echo 10 ;;\n'
                              '  hw.perflevel0.physicalcpu) echo 4 ;;\n'
                              '  hw.physicalcpu) echo 10 ;;\n'
                              '  *) exit 1 ;;\n'
                              'esac\n')
        self.script('nproc', '#!/bin/sh\nexit 127\n')
        self.script('grep', '#!/bin/sh\n'
                            'for arg; do [ "$arg" = /proc/cpuinfo ] && exit 1; done\n'
                            f'exec {shutil.which("grep")} "$@"\n')
        self.prefix = self.work / 'home'
        (self.prefix / 'bin').mkdir(parents=True)
        (self.prefix / 'models').mkdir()
        (self.prefix / 'models/model.gguf').touch()
        server = self.prefix / 'bin/llama-server'
        server.write_text('#!/usr/bin/env python3\n'
                          'import json, os, sys\n'
                          "print(json.dumps({'argv': sys.argv[1:], 'x1': os.environ.get('GGML_X1')}))\n")
        server.chmod(0o755)

    def script(self, name, body):
        path = self.tools / name
        path.write_text(body)
        path.chmod(0o755)

    def env(self, **fixtures):
        env = {**os.environ, 'OPENSET_LLM_HOME': str(self.prefix),
               'PATH': str(self.tools) + os.pathsep + os.environ['PATH']}
        env.pop('GGML_X1', None)
        env.update(fixtures)
        return env

    def check(self, *args, **fixtures):
        return subprocess.run([BASH, str(ROOT / 'install.sh'), '--check', *args], env=self.env(**fixtures),
                              text=True, capture_output=True, timeout=30)

    def serve(self, *args, **fixtures):
        return subprocess.run([BASH, str(ROOT / 'serve'), '--no-resume', *args], env=self.env(**fixtures),
                              text=True, capture_output=True, timeout=30)

    def payload(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout.strip().splitlines()[-1])

    def test_check_names_apple_silicon_and_the_chip(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        out = result.stdout + result.stderr
        self.assertIn('Apple Silicon', out)
        self.assertIn('Apple M4', out)

    def test_check_rejects_intel_macs(self):
        result = self.check(FIXTURE_ARCH='x86_64')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Intel Macs are not supported', result.stdout + result.stderr)

    def test_check_needs_16_gb_of_memory(self):
        result = self.check(FIXTURE_MEM_BYTES='8589934592')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('at least 16 GB', result.stdout + result.stderr)

    def test_check_rejects_portable_on_a_mac(self):
        result = self.check('--portable')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--portable builds x86-64 binaries', result.stdout + result.stderr)

    def test_serve_puts_the_model_on_the_gpu_without_speculation(self):
        result = self.serve()
        payload = self.payload(result)
        argv = payload['argv']
        self.assertEqual(argv[argv.index('-ngl') + 1], '99')
        self.assertNotIn('--spec-type', argv)
        self.assertEqual(argv[argv.index('-t') + 1], '4')
        self.assertIn('on a Mac speculation is off', result.stderr)

    def test_serve_spec_flag_forces_speculation_without_x1(self):
        payload = self.payload(self.serve('--spec'))
        argv = payload['argv']
        self.assertIn('--spec-type', argv)
        self.assertEqual(argv[argv.index('--spec-type') + 1], 'draft-mtp')
        self.assertIsNone(payload['x1'])

    def test_compact_attention_caches_are_not_available_on_a_mac(self):
        for flag in ('--kv8', '--kv5'):
            result = self.serve(flag)
            self.assertEqual(result.returncode, 2, flag)
            self.assertIn('not available on a Mac', result.stderr, flag)


if __name__ == '__main__':
    unittest.main()
