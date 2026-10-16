#!/usr/bin/env python3
"""Matched profile samples in fresh app processes; no real-cache ownership switch.
Run only after the long soak exits. The local seed has a shared 1 MiB/s budget.
"""
import argparse
import hashlib
import json
import math
import os
import signal
import pathlib
import random
import shutil
import statistics
import subprocess
import time


def p95(values):
    return sorted(values)[math.ceil(.95 * len(values)) - 1]


def active_players():
    output = subprocess.check_output(['/bin/ps', '-axo', 'command='], text=True)
    return [row for row in output.splitlines() if row.split(' ')[0].endswith('/PeerStream.app/Contents/MacOS/PeerStream')]


def summarize(rows, requested):
    groups = {}
    for row in rows:
        key = row['backend'] + ':' + row['kind']
        groups.setdefault(key, []).append(row)
    summary = {}
    for key, values in groups.items():
        first = [r['visiblePlaybackMs'] for r in values]
        cached = [r['seekPositionConfirmedMs'] for r in values if r['fileCompleteBeforeSeek'] is True or r['kind'] == 'local']
        summary[key] = {
            'samples': len(values), 'requestedSamples': requested,
            'firstFrameMedianMs': statistics.median(first), 'firstFrameP95Ms': p95(first),
            'cachedPositionSeekSamples': len(cached), 'cachedPositionSeekP95Ms': p95(cached) if cached else None,
            'audioChangeP95Ms': p95([r['audioChangeAcknowledgedMs'] for r in values]),
            'subtitleChangeP95Ms': p95([r['subtitleChangeAcknowledgedMs'] for r in values]),
            'combinedPhysicalFootprintMedianBytes': statistics.median(r['combinedPhysicalFootprintBytes'] for r in values),
        }
    native = summary.get('native:cold')
    service = summary.get('service:cold')
    warm_native = summary.get('native:warm')
    warm_service = summary.get('service:warm')
    enough = requested >= 20 and len(summary) == 8 and bool(native and service and warm_native and warm_service) and all(g['samples'] >= requested for g in summary.values())
    improvement = None if not native or not service else 1 - service['firstFrameMedianMs'] / native['firstFrameMedianMs']
    memory_ratios = {
        kind: summary['service:' + kind]['combinedPhysicalFootprintMedianBytes'] / summary['native:' + kind]['combinedPhysicalFootprintMedianBytes']
        for kind in ['cold', 'warm', 'partial'] if 'service:' + kind in summary and 'native:' + kind in summary
    }
    memory_ratio = max(memory_ratios.values()) if memory_ratios else None
    isolation = all(r.get('helperCrashUiSurvivedAndPositionRecovered') is True and r.get('remoteCacheAdapterRoundTripAndRestartVerified') is True for r in rows if r['backend'] == 'service' and r['kind'] == 'warm') and any(r['backend'] == 'service' and r['kind'] == 'warm' for r in rows)
    startup = bool(summary) and all(g['firstFrameP95Ms'] <= (2000 if key.split(':')[1] in ['local', 'warm'] else 10000) for key, g in summary.items())
    controls = bool(summary) and all(g['audioChangeP95Ms'] <= 500 and g['subtitleChangeP95Ms'] <= 500 for g in summary.values())
    cached_seek = bool(summary) and all(g['cachedPositionSeekP95Ms'] is None or g['cachedPositionSeekP95Ms'] <= 1000 for g in summary.values()) and all(
        summary.get(key, {}).get('cachedPositionSeekSamples', 0) >= requested
        for key in ['native:local', 'native:warm', 'service:warm'])
    no_material_regression = memory_ratio is not None and memory_ratio <= 1.1 and cached_seek and all(
        summary['service:' + kind]['firstFrameP95Ms'] <= max(summary['native:' + kind]['firstFrameP95Ms'] * 1.1, summary['native:' + kind]['firstFrameP95Ms'] + 250)
        for kind in ['cold', 'warm', 'partial'] if 'service:' + kind in summary and 'native:' + kind in summary)
    return {
        'groups': summary,
        'predeclaredBottleneck': 'Cold selected-source tap to first rendered frame on the shared 1 MiB/s original local seed, Balanced profile.',
        'predeclaredRegressionBudgets': {'combinedMemoryRatio': 1.1, 'startupP95': 'No increase exceeding both 10 percent and 250 ms', 'cachedPositionSeekP95Ms': 1000, 'trackAcknowledgementP95Ms': 500, 'minimumSamplesPerCase': 20},
        'coldMedianImprovementFraction': improvement,
        'serviceCombinedMemoryRatio': memory_ratio,
        'serviceCombinedMemoryRatiosByCase': memory_ratios,
        'helperCrashIsolationAndPositionRecoveryPassed': isolation,
        'controlledStartupTargetsMet': enough and startup,
        'noMaterialRegressionObserved': no_material_regression,
        'cachedPositionSeekTargetMet': enough and cached_seek,
        'trackAcknowledgementTargetMet': enough and controls,
        'performanceOrIsolationGateMet': enough and startup and controls and no_material_regression and ((improvement is not None and improvement >= .15) or isolation),
        'visualSeekLatencyVerified': False,
        'serviceAdoptionAllowed': False,
        'remainingAdoptionGates': ['Signed distribution and oldest-supported-OS runtime checks', 'Compositor-frame seek validation', 'Independent SSD authorization for persistent background mode'],
    }


def main(args):
    if active_players():
        raise RuntimeError('Close the existing player before running matched samples.')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    snapshot = args.storage_root / 'temp' / ('matrix-metadata-' + str(time.time_ns()))
    snapshot.mkdir(parents=True)
    before = {}
    for file in (args.storage_root / 'data').glob('*.json'):
        before[file.name] = hashlib.sha256(file.read_bytes()).hexdigest()
        shutil.copy2(file, snapshot / file.name)
    rows = []
    code = 0
    changed = []
    build_log = args.output.with_suffix('.build.log')
    app = pathlib.Path('build/macos/Build/Products/Profile/PeerStream.app').resolve()
    try:
        with build_log.open('w') as output:
            subprocess.run(['flutter', 'build', 'macos', '--profile', '--target', 'integration_test/player_matrix_test.dart', '--dart-define=PEERSTREAM_PLAYER_FIXTURE=' + str(args.fixture.resolve())], stdout=output, stderr=subprocess.STDOUT, check=True)
            if args.native_prefix:
                subprocess.run(['python3', 'tool/bundle_native_dependencies.py', str(app), '--native-prefix', str(args.native_prefix.resolve())], stdout=output, stderr=subprocess.STDOUT, check=True)
                subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', 'macos/Runner/DebugProfile.entitlements', str(app)], stdout=output, stderr=subprocess.STDOUT, check=True)
                subprocess.run(['python3', 'tool/audit_macos_package.py', str(app), '--output', str(args.output.with_suffix('.package-audit.json'))], stdout=output, stderr=subprocess.STDOUT, check=True)
        cases = [('native', 'local'), ('native', 'http'), ('native', 'cold'), ('native', 'warm'), ('native', 'partial'), ('service', 'cold'), ('service', 'warm'), ('service', 'partial')]
        rng = random.Random(20261014)
        for number in range(args.samples):
            order = list(cases)
            rng.shuffle(order)
            for backend, kind in order:
                log = args.output.parent / f'{args.output.stem}-{number:02d}-{backend}-{kind}.log'
                command = ['flutter', 'drive', '--no-pub', '-d', 'macos', '--profile', '--driver', 'tool/integration_driver.dart', '--target', 'integration_test/player_matrix_test.dart', '--use-application-binary', str(app), '--dart-entrypoint-args=' + backend, '--dart-entrypoint-args=' + kind]
                with log.open('w') as output:
                    trial = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
                    try:
                        trial.wait(timeout=180)
                    except subprocess.TimeoutExpired:
                        os.killpg(trial.pid, signal.SIGTERM)
                        try:
                            trial.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            os.killpg(trial.pid, signal.SIGKILL)
                            trial.wait(timeout=5)
                        raise
                results = []
                for line in log.read_text().splitlines():
                    if '[MatrixVerification]' in line and '{' in line:
                        results.append(json.loads(line[line.index('{'):]))
                if trial.returncode != 0 or len(results) != 1:
                    raise RuntimeError(f'Trial failed: {log.name}; exit {trial.returncode}')
                result = results[0]
                if result['backend'] != backend or result['kind'] != kind:
                    raise RuntimeError('Desktop entrypoint arguments were not honored; refusing mislabeled results.')
                if result['appPhysicalFootprintBytes'] is None:
                    raise RuntimeError('Combined physical footprint measurement is unavailable.')
                rows.append(result)
                args.output.write_text(json.dumps({'state': 'running', 'results': rows, 'summary': summarize(rows, args.samples)}, indent=2))
                print(json.dumps({'sample': number + 1, 'backend': backend, 'kind': kind, 'firstFrameMs': result['visiblePlaybackMs'], 'completedTrials': len(rows)}), flush=True)
    except Exception as error:
        code = 1
        print(str(error), flush=True)
    finally:
        for name, digest in before.items():
            file = args.storage_root / 'data' / name
            if not file.exists() or hashlib.sha256(file.read_bytes()).hexdigest() != digest or file.stat().st_mtime_ns != (snapshot / name).stat().st_mtime_ns:
                changed.append(name)
        changed.extend(sorted(file.name for file in (args.storage_root / 'data').glob('*.json') if file.name not in before))
        if changed:
            code = 1
        else:
            shutil.rmtree(snapshot)
        args.output.write_text(json.dumps({'state': 'finished', 'exitCode': code, 'changedMetadataFiles': changed, 'metadataSnapshot': str(snapshot) if changed else None, 'results': rows, 'summary': summarize(rows, args.samples)}, indent=2))
    raise SystemExit(code)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', type=pathlib.Path, required=True)
    parser.add_argument('--storage-root', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--samples', type=int, default=20)
    parser.add_argument('--native-prefix', type=pathlib.Path, help='Explicit verified source-build prefix; never auto-selected.')
    parsed = parser.parse_args()
    if parsed.samples < 1:
        parser.error('--samples must be positive')
    main(parsed)
