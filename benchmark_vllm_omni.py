#!/usr/bin/env python3
"""Benchmark vllm-omni TTFT and TPOT across multiple requests."""

import base64
import json
import os
import sys
import time
import statistics
import wave
import requests


def benchmark_request(gateway_url, model, audio_url, input_type="audio_url"):
    """Single request, return TTFT, TPOT, and audio data."""
    if input_type == "audio_url":
        audio_content = {"type": "audio_url", "audio_url": {"url": audio_url}}
    elif input_type == "input_audio":
        r = requests.get(audio_url, timeout=30)
        r.raise_for_status()
        b64 = base64.b64encode(r.content).decode()
        audio_content = {"type": "input_audio", "input_audio": {"data": b64, "format": "mp3"}}
    elif input_type == "audio":
        r = requests.get(audio_url, timeout=30)
        r.raise_for_status()
        b64 = base64.b64encode(r.content).decode()
        audio_content = {"type": "audio", "audio": {"data": b64}}
    else:
        raise ValueError(f"Unknown input_type: {input_type}")

    start_time = time.time()
    resp = requests.post(
        f"{gateway_url}/v1/chat/completions",
        json={
            "model": model,
            "messages": [{"role": "user", "content": [audio_content]}],
            "modalities": ["text", "audio"],
            "stream": True,
        },
        stream=True,
        timeout=120,
    )
    resp.raise_for_status()

    ttft = None
    last_token_time = None
    tpot_values = []
    audio_pcm = bytearray()

    for line in resp.iter_lines():
        if not line or not line.startswith(b"data: "):
            continue
        data = line[6:]
        if data == b"[DONE]":
            break
        chunk = json.loads(data)
        delta = chunk.get("choices", [{}])[0].get("delta", {})
        content = delta.get("content")
        if not content:
            continue

        now = time.time()
        if ttft is None:
            ttft = now - start_time
        elif last_token_time is not None:
            tpot_values.append(now - last_token_time)
        last_token_time = now

        modality = chunk.get("modality", "text")
        if modality == "audio":
            content += "=" * (-len(content) % 4)
            audio_pcm.extend(base64.b64decode(content))

    total_time = time.time() - start_time
    avg_tpot = statistics.mean(tpot_values) if tpot_values else 0

    return {
        "ttft": ttft,
        "tpot": avg_tpot,
        "total_time": total_time,
        "audio_pcm": bytes(audio_pcm),
        "chunks": len(tpot_values) + 1 if tpot_values else 0,
    }


def calculate_percentiles(values):
    """Calculate p50, p95, p99."""
    sorted_vals = sorted(values)
    n = len(sorted_vals)
    return {
        "min": sorted_vals[0],
        "max": sorted_vals[-1],
        "mean": statistics.mean(sorted_vals),
        "median": statistics.median(sorted_vals),
        "p95": sorted_vals[int(n * 0.95)] if n >= 20 else sorted_vals[-1],
        "p99": sorted_vals[int(n * 0.99)] if n >= 100 else sorted_vals[-1],
    }


def run_benchmark(gateway_url, model, audio_url, num_requests, input_type, delay):
    """Run benchmark with multiple requests."""
    # Create output folder
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    output_dir = f"/tmp/benchmark_{timestamp}"
    os.makedirs(output_dir, exist_ok=True)

    print(f"Benchmarking {num_requests} requests to {gateway_url}")
    print(f"Model: {model}")
    print(f"Audio: {audio_url}")
    print(f"Input type: {input_type}")
    print(f"Delay between requests: {delay}s")
    print(f"Output folder: {output_dir}")
    print("-" * 60)

    results = []
    for i in range(num_requests):
        try:
            result = benchmark_request(gateway_url, model, audio_url, input_type)
            results.append(result)
            ttft_ms = result["ttft"] * 1000 if result["ttft"] else 0
            print(f"Request {i+1:3d}: TTFT={ttft_ms:7.1f}ms  chunks={result['chunks']:3d}  audio={len(result['audio_pcm']):6d}B")

            # Save audio file
            if result["audio_pcm"]:
                output_file = os.path.join(output_dir, f"audio_{i+1:03d}.wav")
                with wave.open(output_file, "wb") as w:
                    w.setnchannels(1)
                    w.setsampwidth(2)
                    w.setframerate(24000)
                    w.writeframes(result["audio_pcm"])
        except Exception as e:
            print(f"Request {i+1:3d}: FAILED - {e}")
        if delay > 0 and i < num_requests - 1:
            time.sleep(delay)

    # Calculate statistics
    ttfts = [r["ttft"] * 1000 for r in results if r["ttft"] is not None]
    tpots = [r["tpot"] * 1000 for r in results if r["tpot"] > 0]
    total_times = [r["total_time"] * 1000 for r in results]

    print("\n" + "=" * 60)
    print("RESULTS")
    print("=" * 60)

    if ttfts:
        ttft_stats = calculate_percentiles(ttfts)
        print(f"\nTTFT (ms):")
        print(f"  Min:    {ttft_stats['min']:7.1f}")
        print(f"  Max:    {ttft_stats['max']:7.1f}")
        print(f"  Mean:   {ttft_stats['mean']:7.1f}")
        print(f"  Median: {ttft_stats['median']:7.1f}")
        print(f"  P95:    {ttft_stats['p95']:7.1f}")
        print(f"  P99:    {ttft_stats['p99']:7.1f}")

    if tpots:
        tpot_stats = calculate_percentiles(tpots)
        print(f"\nTPOT (ms):")
        print(f"  Min:    {tpot_stats['min']:7.1f}")
        print(f"  Max:    {tpot_stats['max']:7.1f}")
        print(f"  Mean:   {tpot_stats['mean']:7.1f}")
        print(f"  Median: {tpot_stats['median']:7.1f}")
        print(f"  P95:    {tpot_stats['p95']:7.1f}")
        print(f"  P99:    {tpot_stats['p99']:7.1f}")

    if total_times:
        total_stats = calculate_percentiles(total_times)
        print(f"\nTotal Time (ms):")
        print(f"  Min:    {total_stats['min']:7.1f}")
        print(f"  Max:    {total_stats['max']:7.1f}")
        print(f"  Mean:   {total_stats['mean']:7.1f}")
        print(f"  Median: {total_stats['median']:7.1f}")
        print(f"  P95:    {total_stats['p95']:7.1f}")
        print(f"  P99:    {total_stats['p99']:7.1f}")

    # Cache analysis
    if len(ttfts) >= 2:
        first_ttft = ttfts[0]
        rest_ttfts = ttfts[1:]
        rest_median = statistics.median(rest_ttfts)
        cache_benefit = (first_ttft - rest_median) / first_ttft * 100
        print(f"\nCache Analysis:")
        print(f"  First request TTFT: {first_ttft:.1f}ms")
        print(f"  Subsequent requests median: {rest_median:.1f}ms")
        print(f"  Cache benefit: {cache_benefit:.1f}%")

    print(f"\nTotal requests: {len(results)}")
    print(f"Successful: {len(ttfts)}")
    print(f"Failed: {num_requests - len(ttfts)}")
    print(f"Audio files: {output_dir}/audio_*.wav")

    return results


if __name__ == "__main__":
    default_audio = "https://vllm-public-assets.s3.us-west-2.amazonaws.com/multimodal_asset/mary_had_lamb.ogg"

    gateway_url = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080"
    num_requests = int(sys.argv[2]) if len(sys.argv) > 2 else 10
    input_type = sys.argv[3] if len(sys.argv) > 3 else "audio_url"
    audio_url = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else default_audio
    delay = float(sys.argv[5]) if len(sys.argv) > 5 else 1.0

    run_benchmark(
        gateway_url=gateway_url,
        model="Qwen/Qwen3-Omni-30B-A3B-Instruct",
        audio_url=audio_url,
        num_requests=num_requests,
        input_type=input_type,
        delay=delay,
    )
