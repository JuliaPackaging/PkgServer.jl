import http from 'k6/http';
import { sleep, check, group } from 'k6';
import { registry_resources, package_resources, artifact_resources, bad_resources } from './data/resources.js'
import { Trend, Rate } from 'k6/metrics';

export let options = {
    stages : [
        // Over 10s, ramp up from 0 users to 10
        { duration: '10s', target: 10},
        // Hold steady at 10 users for another 60s (enough time for us to get through initial compilation)
        { duration: '60s', target: 10},

        // Tap the accelerator, head up to 100 users and dawdle up there for a bit
        { duration: '10s', target: 50},
        { duration: '60s', target: 50},

        // Pop the clutch, do a wheelie on this garbage truck and scream up to 1000 users
        //{ duration: '30s', target: 1000},
        //{ duration: '60s', target: 1000},

        // // Clap your hands, place them firmly upon the disk, and open a portal to the underworld
        // { duration: '30s', target: 10000},
        // { duration: '60s', target: 10000},
    ],
};

function random_choice(list) {
    return list[Math.floor(Math.random() * list.length)];
}

let trend_reg = Trend('timing_registry');
let trend_pkg = Trend('timing_package');
let trend_art = Trend('timing_artifact');
let trend_404 = Trend('timing_404');

let trend_tasks = Trend('live_tasks');
let rate_errors = Rate('errors');

export default function () {
    let base = 'http://localhost:8000';
    let params = {redirects: 0};

    let check_200 = {'200 OK': (r) => r.status === 200};
    let check_302 = {'302 OK': (r) => r.status === 302};
    let check_404 = {'404': (r) => r.status === 404}
    
    // Get ourselves a registry, a package and an artifact
    let resources = [
        [random_choice(registry_resources), trend_reg, check_200],
        [random_choice(package_resources), trend_pkg, check_200],
        [random_choice(artifact_resources), trend_art, check_200],
        [random_choice(bad_resources), trend_404, check_404],
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
        let num_live_tasks = res.json("live_tasks")
        if (num_live_tasks != undefined) {
            trend_tasks.add(num_live_tasks);
        }
        sleep(0.01);
    }
}
