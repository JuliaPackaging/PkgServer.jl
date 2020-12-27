import http from 'k6/http';
import { sleep, check } from 'k6';
import { Trend, Rate } from 'k6/metrics';

export let options = {
    stages : [
        // Over 10s, ramp up from 0 users to 10
        { duration: '10s', target: 10},
        // Hold steady at 10 users for another 10s (enough time for us to get through initial compilation)
        { duration: '10s', target: 10},

        // Pop the clutch, do a wheelie on this garbage truck and scream up to 1000 users
        { duration: '10s', target: 100},
        { duration: '30s', target: 100},
    ],
};


let trend_reg = Trend('timing_registry');
let trend_pkg = Trend('timing_package');
let trend_art = Trend('timing_artifact');
let trend_meta = Trend('timing_meta');
let trend_404 = Trend('timing_404');

let trend_tasks = Trend('live_tasks');
let rate_errors = Rate('errors');

export default function () {
    let base = 'http://localhost:8000';
    let params = {redirects: 0};

    let check_200 = {'200 OK': (r) => r.status === 200};
    let check_404 = {'404': (r) => r.status === 404}
    
    // Get ourselves a registry, a package and an artifact
    let resources = [
        ["/registry/23338594-aafe-5451-b93e-139f81909106/05a3c5553c916ff9585b6393860e91f51d931448", trend_reg, check_200],
        ["/package/009559a3-9522-5dbb-924b-0b6ed2b22bb9/8a692f817f1a6c15ef4913a0ffefa6163117f43d", trend_pkg, check_200],
        ["/artifact/004eafdccbb9f9bd68b9c3a01a25312d2126fc8f", trend_art, check_200],
        ["/foofoo/roflmao", trend_404, check_404],
    ];
    for (let idx in resources) {
        let [resource, trend, check_functor] = resources[idx];
        let res = http.get(base + resource, params);
        rate_errors.add(!check(res, check_functor));
        trend.add(res.timings.duration);

        // Sleep a bit so that our rps go up with our VUs
        sleep(0.01);
    }

    // Hit /meta and ask how many tasks are currently running, if any
    {
        let res = http.get(base + "/meta", params);
        rate_errors.add(!check(res, check_200));
        trend_meta.add(res.timings.duration);
        let num_live_tasks = res.json("live_tasks")
        if (num_live_tasks != undefined) {
            trend_tasks.add(num_live_tasks);
        }
        sleep(0.01);
    }
}
