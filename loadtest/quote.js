// k6 load test for quote-api, sent through the Traefik Ingress (not the Service or a pod).
//   PROFILE=baseline  quiet load (2 req/s): measures the no-contention latency the thresholds are based on
//   PROFILE=scale     sustained load that pushes the HPA past 3 replicas (default)
//   PROFILE=stress    stepped arrival rate to find the max sustainable RPS at 6 replicas
//   PROFILE=saturate  7 min above the measured max, to check the PrometheusRule actually fires
// Threshold justification (from the measured baseline): see LOADTEST.md.
import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://server';
const PROFILE = __ENV.PROFILE || 'scale';

const profiles = {
  baseline: {
    executor: 'constant-arrival-rate',
    rate: 2, timeUnit: '1s', duration: '60s',
    preAllocatedVUs: 5, maxVUs: 10,
  },
  scale: {
    // 12 req/s fits 3 pods (~15 req/s at their CPU limits) but puts them at ~170% of the CPU
    // request, so the HPA (target 60%) scales to its max while latency stays inside the SLO.
    executor: 'ramping-arrival-rate',
    startRate: 2, timeUnit: '1s',
    preAllocatedVUs: 20, maxVUs: 60,
    stages: [
      { target: 12, duration: '1m' },
      { target: 12, duration: '5m' },
      { target: 0, duration: '30s' },
    ],
  },
  stress: {
    executor: 'ramping-arrival-rate',
    startRate: 10, timeUnit: '1s',
    preAllocatedVUs: 40, maxVUs: 150,
    stages: [
      { target: 15, duration: '1m' }, { target: 15, duration: '1m' },
      { target: 20, duration: '30s' }, { target: 20, duration: '1m' },
      { target: 25, duration: '30s' }, { target: 25, duration: '1m' },
      { target: 30, duration: '30s' }, { target: 30, duration: '1m' },
      { target: 35, duration: '30s' }, { target: 35, duration: '1m' },
    ],
  },
  saturate: {
    executor: 'constant-arrival-rate',
    rate: 36, timeUnit: '1s', duration: '7m',
    preAllocatedVUs: 60, maxVUs: 200,
  },
};

export const options = {
  scenarios: { [PROFILE]: profiles[PROFILE] },
  // Stress and saturate are meant to break the service, so they report without failing the run.
  thresholds: ['stress', 'saturate'].includes(PROFILE) ? {} : {
    // Error budget: 0 errors in 3 baseline runs (363 requests); 1% allows a stray reset during pod churn.
    http_req_failed: ['rate<0.01'],
    // Measured baseline (3 runs, 2 req/s): median 177/166/159ms; p95 214/198/205ms; p99 378/216/216ms.
    // The limits are ~2x the *worst* baseline tail (p95 214ms, p99 378ms): room for queueing while the HPA reacts,
    // but far below the multi-second latency of a saturated pod.
    http_req_duration: ['p(95)<400', 'p(99)<800'],
    checks: ['rate>0.99'],
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const res = http.get(`${BASE_URL}/api/quote`, { timeout: '10s', tags: { name: '/api/quote' } });
  check(res, {
    'status 200': (r) => r.status === 200,
    'has a quote': (r) => r.status === 200 && !!r.json('text'),
  });
}
