#!/usr/bin/env python3
"""Replay OpenSky capture files and report motion accuracy/smoothness metrics.

Input format is the JSONL capture produced during field studies:

  {"wall_time": ..., "server_time": ..., "observations": [...]}

The optional summary file narrows evaluation to confirmed arrival/departure
tracks, matching the stricter LSZH classifier used for the ZRH study.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
from collections import defaultdict

LSZH_ELEVATION_METERS = 432.0
OBSERVER = {"lat": 47.451210, "lon": 8.557410, "alt": 432.0}
EARTH_RADIUS_METERS = 6_371_000.0


def enu(ref: dict, target: dict) -> tuple[float, float, float]:
    lat = math.radians(ref["lat"])
    meters_per_lat = 111_132.92 - 559.82 * math.cos(2 * lat) + 1.175 * math.cos(4 * lat)
    meters_per_lon = 111_412.84 * math.cos(lat) - 93.5 * math.cos(3 * lat)
    ref_alt = ref.get("alt") if ref.get("alt") is not None else LSZH_ELEVATION_METERS
    target_alt = target.get("alt") if target.get("alt") is not None else LSZH_ELEVATION_METERS
    return (
        (target["lon"] - ref["lon"]) * meters_per_lon,
        (target["lat"] - ref["lat"]) * meters_per_lat,
        target_alt - ref_alt,
    )


def coordinate(ref: dict, east: float, north: float, up: float = 0) -> dict:
    lat = math.radians(ref["lat"])
    meters_per_lat = 111_132.92 - 559.82 * math.cos(2 * lat) + 1.175 * math.cos(4 * lat)
    meters_per_lon = 111_412.84 * math.cos(lat) - 93.5 * math.cos(3 * lat)
    ref_alt = ref.get("alt") if ref.get("alt") is not None else LSZH_ELEVATION_METERS
    return {
        "lat": ref["lat"] + north / meters_per_lat,
        "lon": ref["lon"] + east / meters_per_lon,
        "alt": ref_alt + up,
    }


def velocity_vector(speed: float | None, track: float | None) -> tuple[float, float]:
    if speed is None or track is None:
        return 0.0, 0.0
    radians = math.radians(track)
    return speed * math.sin(radians), speed * math.cos(radians)


def angular_delta_degrees(before: dict, after: dict) -> float | None:
    before_vector = enu(OBSERVER, before)
    after_vector = enu(OBSERVER, after)
    before_length = math.sqrt(sum(component * component for component in before_vector))
    after_length = math.sqrt(sum(component * component for component in after_vector))
    if before_length < 1 or after_length < 1:
        return None
    dot = sum(a * b for a, b in zip(before_vector, after_vector))
    cosine = max(-1, min(1, dot / (before_length * after_length)))
    return math.degrees(math.acos(cosine))


def horizontal_distance_meters(before: dict, after: dict) -> float:
    east, north, _ = enu(before, after)
    return math.hypot(east, north)


def distinct(samples: list[dict]) -> list[dict]:
    seen = set()
    result = []
    for sample in samples:
        key = (sample["t"], round(sample["lat"], 6), round(sample["lon"], 6), sample["ground"])
        if key in seen:
            continue
        seen.add(key)
        result.append(sample)
    return sorted(result, key=lambda item: (item["t"], item["wall"]))


def load_capture(path: str, summary_path: str | None) -> tuple[list[dict], dict[str, list[dict]]]:
    included_ids: set[str] | None = None
    if summary_path:
        with open(summary_path) as handle:
            summary = json.load(handle)
        included_ids = {item["icao24"] for item in summary.get("classifications", [])}

    polls = []
    tracks: dict[str, list[dict]] = defaultdict(list)
    with open(path) as handle:
        for line in handle:
            poll = json.loads(line)
            observations = []
            poll_wall_time = poll["wall_time"]
            for observation in poll.get("observations", []):
                icao = observation["icao24"]
                if included_ids is not None and icao not in included_ids:
                    continue
                altitude = observation.get("altitude")
                on_ground = observation.get("on_ground", False)
                sample = {
                    "icao": icao,
                    "lat": observation["lat"],
                    "lon": observation["lon"],
                    "alt": LSZH_ELEVATION_METERS if on_ground else (altitude or LSZH_ELEVATION_METERS),
                    "ground": on_ground,
                    "speed": observation.get("velocity"),
                    "track": observation.get("true_track"),
                    "vr": 0 if on_ground else (observation.get("vertical_rate") or 0),
                    "t": observation.get("time_position")
                    or observation.get("last_contact")
                    or poll["server_time"],
                    "wall": observation.get("wall_time", poll_wall_time),
                }
                observations.append(sample)
                tracks[icao].append(sample)
            polls.append({"wall": poll_wall_time, "observations": observations})

    return polls, {icao: distinct(samples) for icao, samples in tracks.items()}


def downsample_polls(polls: list[dict], interval_seconds: float) -> list[dict]:
    result = []
    next_time = None
    for poll in polls:
        if next_time is None or poll["wall"] >= next_time:
            result.append(poll)
            next_time = poll["wall"] + interval_seconds
    return result


def ground_elapsed_seconds(seconds: float) -> float:
    if seconds <= 5:
        return seconds
    return min(5 + 5 * (1 - math.exp(-(seconds - 5) / 5)), 12)


def target_estimate(history: list[dict], wall: float, delay: float) -> tuple[dict, dict] | None:
    evaluation_time = wall - delay
    samples = distinct(history)
    if not samples:
        return None

    for before, after in zip(samples, samples[1:]):
        gap = after["t"] - before["t"]
        if before["t"] <= evaluation_time < after["t"] and 0 < gap <= 20:
            fraction = (evaluation_time - before["t"]) / gap
            east, north, up = enu(before, after)
            return coordinate(before, east * fraction, north * fraction, up * fraction), after

    prior = [sample for sample in samples if sample["t"] <= evaluation_time]
    sample = prior[-1] if prior else samples[0]
    elapsed = max(0, min(30, evaluation_time - sample["t"]))
    east_speed, north_speed = velocity_vector(sample["speed"], sample["track"])
    if sample["ground"]:
        if (sample["speed"] or 0) < 2:
            east_speed = 0
            north_speed = 0
        elapsed = ground_elapsed_seconds(elapsed)
        return coordinate(sample, east_speed * elapsed * 0.99, north_speed * elapsed * 0.99, 0), sample

    return coordinate(
        sample,
        east_speed * elapsed * 0.99,
        north_speed * elapsed * 0.99,
        (sample["vr"] or 0) * elapsed,
    ), sample


def truth_at(tracks: dict[str, list[dict]], icao: str, wall: float) -> dict | None:
    samples = tracks.get(icao, [])
    for before, after in zip(samples, samples[1:]):
        gap = after["t"] - before["t"]
        if before["t"] <= wall <= after["t"] and gap > 0:
            fraction = (wall - before["t"]) / gap
            east, north, up = enu(before, after)
            return coordinate(before, east * fraction, north * fraction, up * fraction)

    if samples:
        sample = samples[-1]
        elapsed = wall - sample["t"]
        if 0 <= elapsed <= 5:
            east_speed, north_speed = velocity_vector(sample["speed"], sample["track"])
            return coordinate(sample, east_speed * elapsed, north_speed * elapsed, (sample["vr"] or 0) * elapsed)
    return None


class ResidualSmoother:
    def __init__(self) -> None:
        self.state: dict[str, dict] = {}

    def smooth(self, icao: str, target: dict, metadata: dict, wall: float) -> dict:
        previous = self.state.get(icao)
        if previous is None or wall - previous["wall"] > 1:
            self.state[icao] = {"coord": target, "metadata": metadata, "wall": wall}
            return target

        elapsed = max(0, wall - previous["wall"])
        predicted = self._advance(previous["coord"], previous["metadata"], elapsed)
        is_ground = metadata["ground"]
        was_ground = previous["metadata"]["ground"]
        if is_ground:
            response = 0.85 if not was_ground else 2.0
        elif was_ground:
            response = 0.65
        else:
            response = 1.0

        scale = math.exp(-elapsed / max(response, 0.001))
        east, north, up = enu(target, predicted)
        if is_ground:
            up = 0
        rendered = coordinate(target, east * scale, north * scale, up * scale)
        if is_ground:
            rendered["alt"] = target["alt"]
        self.state[icao] = {"coord": rendered, "metadata": metadata, "wall": wall}
        return rendered

    def _advance(self, coordinate_: dict, metadata: dict, elapsed: float) -> dict:
        east_speed, north_speed = velocity_vector(metadata["speed"], metadata["track"])
        if metadata["ground"] and (metadata["speed"] or 0) < 2:
            east_speed = 0
            north_speed = 0
        return coordinate(
            coordinate_,
            east_speed * elapsed,
            north_speed * elapsed,
            0 if metadata["ground"] else (metadata["vr"] or 0) * elapsed,
        )


def distribution(values: list[float]) -> dict:
    clean = sorted(value for value in values if value is not None and not math.isnan(value))

    def percentile(fraction: float) -> float:
        return clean[min(len(clean) - 1, round((len(clean) - 1) * fraction))]

    return {
        "n": len(clean),
        "median": statistics.median(clean),
        "p75": percentile(0.75),
        "p90": percentile(0.9),
        "p95": percentile(0.95),
        "mean": statistics.mean(clean),
        "over_0_25": sum(value > 0.25 for value in clean) / len(clean),
        "over_1": sum(value > 1 for value in clean) / len(clean),
    }


def simulate(
    polls: list[dict],
    tracks: dict[str, list[dict]],
    poll_interval: float,
    frame_rate: float,
    delay: float,
    use_smoother: bool,
) -> dict:
    app_polls = downsample_polls(polls, poll_interval)
    start = app_polls[0]["wall"]
    end = app_polls[-1]["wall"]
    frame_step = 1 / frame_rate
    histories: dict[str, list[dict]] = defaultdict(list)
    smoother = ResidualSmoother()
    previous_rendered: dict[str, dict] = {}
    poll_index = 0
    accuracy = []
    frame_angular = []
    poll_angular = []

    wall = start
    while wall <= end:
        before_poll = dict(previous_rendered)
        ingested = False
        while poll_index < len(app_polls) and app_polls[poll_index]["wall"] <= wall:
            for observation in app_polls[poll_index]["observations"]:
                histories[observation["icao"]].append(observation)
            poll_index += 1
            ingested = True

        current_rendered = {}
        for icao, history in histories.items():
            estimate = target_estimate(history, wall, delay)
            if estimate is None:
                continue
            target, metadata = estimate
            rendered = smoother.smooth(icao, target, metadata, wall) if use_smoother else target
            current_rendered[icao] = rendered

            truth = truth_at(tracks, icao, wall)
            if truth is not None:
                accuracy.append(horizontal_distance_meters(rendered, truth))
            if icao in previous_rendered:
                angle = angular_delta_degrees(previous_rendered[icao], rendered)
                if angle is not None:
                    frame_angular.append(angle)

        if ingested:
            for icao, after in current_rendered.items():
                if icao in before_poll:
                    angle = angular_delta_degrees(before_poll[icao], after)
                    if angle is not None:
                        poll_angular.append(angle)

        previous_rendered = current_rendered
        wall += frame_step

    return {
        "accuracy_m": distribution(accuracy),
        "frame_angular_deg": distribution(frame_angular),
        "poll_angular_deg": distribution(poll_angular),
    }


def print_metric(name: str, metrics: dict) -> None:
    print(f"\n{name}")
    for label, values in metrics.items():
        suffix = ""
        if "angular" in label:
            suffix = f" >0.25deg={values['over_0_25'] * 100:.1f}% >1deg={values['over_1'] * 100:.1f}%"
        print(
            f"{label:18s} n={values['n']} "
            f"med={values['median']:.3f} p75={values['p75']:.3f} "
            f"p90={values['p90']:.3f} p95={values['p95']:.3f} "
            f"mean={values['mean']:.3f}{suffix}"
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--jsonl", required=True)
    parser.add_argument("--summary")
    parser.add_argument("--poll-interval", type=float, default=5)
    parser.add_argument("--frame-rate", type=float, default=30)
    args = parser.parse_args()

    polls, tracks = load_capture(args.jsonl, args.summary)
    scenarios = [
        ("old_3s_no_smoother", 3, False),
        ("new_no_smoother", 0, False),
        ("new_render_smoother", 0, True),
    ]
    for name, delay, use_smoother in scenarios:
        print_metric(
            name,
            simulate(
                polls,
                tracks,
                poll_interval=args.poll_interval,
                frame_rate=args.frame_rate,
                delay=delay,
                use_smoother=use_smoother,
            ),
        )


if __name__ == "__main__":
    main()
