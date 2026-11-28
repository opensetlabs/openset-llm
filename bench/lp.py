#!/usr/bin/env python3
"""Logprob probe for the identity diagnosis: per arm, a fresh server, the diag prompts, greedy 256 tokens with the top-2
logprobs of every generated token. Shows how close the first diverging token is to a tie.
    python3 lp.py --arms arms_short.json --only ours,ours_ns,ours_a0_ns --prompts prompts_diag.jsonl --out ~/res/lp
"""
import argparse, json, os, shlex, subprocess, tempfile, time, urllib.request
from bench2 import start, stop, post


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arms", required=True)
    ap.add_argument("--only", required=True)
    ap.add_argument("--prompts", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    arms = json.load(open(a.arms))
    P = [json.loads(l) for l in open(a.prompts)]
    os.makedirs(a.out, exist_ok=True)
    for arm in a.only.split(","):
        f = os.path.join(a.out, f"{arm}.jsonl")
        if os.path.exists(f):
            continue
        port, proc, log = start(arm, arms[arm], a.out, "lp")
        rows = []
        try:
            for p in P:
                r = post(port, {"messages": p["messages"], "max_tokens": 256, "temperature": 0, "seed": 0, "cache_prompt": False,
                                "logprobs": True, "top_logprobs": 2, "chat_template_kwargs": {"enable_thinking": False}})
                lp = (r["choices"][0].get("logprobs") or {}).get("content") or []
                rows.append({"prompt_id": p["id"], "text": r["choices"][0]["message"].get("content") or "",
                             "tokens": [[x["token"], x["logprob"], [(y["token"], y["logprob"]) for y in x.get("top_logprobs", [])]] for x in lp]})
        finally:
            stop(proc)
        with tempfile.TemporaryDirectory(dir=a.out) as staging:
            staged = os.path.join(staging, "result.jsonl")
            with open(staged, "w") as fh:
                for x in rows:
                    fh.write(json.dumps(x) + "\n")
            os.replace(staged, f)


if __name__ == "__main__":
    main()
