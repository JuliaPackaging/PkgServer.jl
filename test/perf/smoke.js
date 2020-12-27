import http from 'k6/http';
import { sleep, check } from 'k6';
import { Trend } from 'k6/metrics';

// Simulate 1 user for 4 seconds
export let options = {
    vus: 1,
    duration: '8s',
};

let trend_fast = Trend('should be fast');
let trend_slow = Trend('should be slow');

// Get the root page, /registries, and follow the /registries redirect
export default function () {
    let base = 'http://localhost:8080';

    // Hit the index page (static file)
    {
        let res = http.get(base + '/');
        check(res, {
            '/ 200 OK': (r) => r.status === 200,
        });
        trend_fast.add(res.timings.duration);
        sleep(0.001);
    }

    // Next, hit `/registries`
    {
        let res = http.get(base + '/registries', {redirects: 1});
        check(res, {
            '/registries -> S3 200 OK': (r) => r.status === 200,
        });
        sleep(0.001);
    }

    // Next, /meta
    {
        let res = http.get(base + '/meta', {redirects: 0});
        check(res, {
            '/meta 200 OK': (r) => r.status === 200,
        });
        sleep(0.001);
    }

    // real quick, hit some resources we know are good
    let resources = [
        "/registry/23338594-aafe-5451-b93e-139f81909106/33fbc2e786d0f9442bbb25128ccd0be8744e0ae4",
        "/package/deac9b47-8bc7-5906-a0fe-35ac56dc84c0/388cfc6274cb2a096fa62c6433c9369167d6d0c1",
        "/artifact/95cf198cf7786b9bd01c473acef97a83df3c568f",
    ];
    for (let idx in resources) {
        let res = http.get(base + resources[idx], {redirects: 0});
        check(res, {
            'resource 200 OK': (r) => r.status === 200,
        });
        sleep(0.001);
        trend_slow.add(res.timings.duration);
    }

    // Also a 404
    {
        let res = http.get(base + '/404', {redirects: 0});
        check(res, {
            '/404': (r) => r.status === 404,
        });
        sleep(0.001);
    }
}
