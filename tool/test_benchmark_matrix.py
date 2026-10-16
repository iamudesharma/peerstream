import unittest

from benchmark_matrix import summarize


def fixture(samples=20, *, service_memory=105, service_startup=100):
    rows = []
    for backend, kinds in [('native', ['local', 'http', 'cold', 'warm', 'partial']), ('service', ['cold', 'warm', 'partial'])]:
        for kind in kinds:
            for _ in range(samples):
                rows.append({
                    'backend': backend, 'kind': kind,
                    'visiblePlaybackMs': service_startup if backend == 'service' else 100,
                    'seekPositionConfirmedMs': 50,
                    'audioChangeAcknowledgedMs': 50,
                    'subtitleChangeAcknowledgedMs': 50,
                    'fileCompleteBeforeSeek': kind in ['local', 'warm'],
                    'combinedPhysicalFootprintBytes': service_memory if backend == 'service' else 100,
                    'helperCrashUiSurvivedAndPositionRecovered': backend == 'service' and kind == 'warm',
                    'remoteCacheAdapterRoundTripAndRestartVerified': backend == 'service' and kind == 'warm',
                })
    return rows


class AdoptionEvidenceTests(unittest.TestCase):
    def test_smoke_sample_never_satisfies_repeatability_gate(self):
        self.assertFalse(summarize(fixture(1), 1)['performanceOrIsolationGateMet'])

    def test_fast_startup_does_not_excuse_memory_regression(self):
        result = summarize(fixture(service_memory=111, service_startup=50), 20)
        self.assertGreater(result['coldMedianImprovementFraction'], .15)
        self.assertFalse(result['performanceOrIsolationGateMet'])

    def test_missing_case_and_unverified_cache_cannot_pass(self):
        rows = [row for row in fixture() if row['kind'] != 'partial']
        self.assertFalse(summarize(rows, 20)['performanceOrIsolationGateMet'])
        rows = fixture()
        for row in rows:
            row['fileCompleteBeforeSeek'] = False
        self.assertFalse(summarize(rows, 20)['cachedPositionSeekTargetMet'])

    def test_isolation_with_bounded_memory_remains_gated_for_distribution(self):
        result = summarize(fixture(), 20)
        self.assertTrue(result['performanceOrIsolationGateMet'])
        self.assertFalse(result['serviceAdoptionAllowed'])


if __name__ == '__main__':
    unittest.main()
