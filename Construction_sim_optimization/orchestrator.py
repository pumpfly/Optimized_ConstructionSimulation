"""
orchestrator.py — Genetic Algorithm Orchestrator for the Construction Simulation
=================================================================================

GA lifecycle
------------
1.  Initialise a random population of POPULATION_SIZE individuals.
2.  Encode each individual as a schedule and add it to the pending-task deque.
3.  Workers poll ``/input``:
      - Tasks available  → return next task as JSON, mark as in-flight.
      - Queue empty but generation incomplete → return "wait" (client retries).
      - All generations done → return "finished" (clients exit).
4.  Workers execute the simulation and call ``/handover?id=…&answer=…``.
5.  When *all* results for the current generation are collected:
      a. Compute fitness for each individual (lower time = higher fitness).
      b. Select parents via tournament selection.
      c. Produce offspring via uniform crossover + Gaussian mutation.
      d. Apply elitism: carry the best ELITE_COUNT individuals unchanged.
      e. Log generation statistics and save best schedule to disk.
      f. Increment generation counter; re-fill the task queue.
6.  After MAX_GENERATIONS, mark as finished and workers receive "finished".

Schedule JSON format (matches Godot's expected input)
-----------------------------------------------------
{
    "id": <int>,
    "schedule": {
        "<time_seconds_str>": ["Bagger", "DirtTruck", ...],
        ...
    }
}
"""

from __future__ import annotations

import copy
import json
import logging
import os
import random
import threading
from collections import deque
from dataclasses import dataclass, field
from typing import List, Optional

from flask import Flask, request

# ---------------------------------------------------------------------------
# Configuration constants
# ---------------------------------------------------------------------------

# Port the Flask server listens on (must match the hardcoded URL in main.gd)
SERVER_PORT: int = 7999

# How many individuals are evaluated in parallel per generation.
# Set this equal to the number of simultaneously running Godot workers.
POPULATION_SIZE: int = 20

# Number of GA generations to run before stopping.
MAX_GENERATIONS: int = 50

# Maximum simulation duration in seconds (3 hours of simulated time).
# Agents spawned beyond this time will never appear; avoid it during evolution.
MAX_SIM_TIME: int = 10800  # 3 h × 3600 s

# Spawn-time search space [seconds].  Agents can appear any time in this range.
MIN_SPAWN_TIME: int = 1
MAX_SPAWN_TIME: int = MAX_SIM_TIME

# Agent count constraints
MIN_BAGGERS: int = 1
MAX_BAGGERS: int = 15
MIN_DIRT_TRUCKS: int = 1
MAX_DIRT_TRUCKS: int = 15
MATERIAL_TRUCK_COUNT: int = 2   # fixed by problem — never changes
CRANE_COUNT: int = 1            # fixed by problem — never changes

# GA hyper-parameters
TOURNAMENT_SIZE: int = 3        # competitors in each tournament-selection round
CROSSOVER_PROBABILITY: float = 0.85  # probability that crossover is applied
MUTATION_RATE: float = 0.15     # per-gene probability of a spawn-time mutation
MUTATION_SIGMA: float = 600.0   # std-dev (seconds) for Gaussian time mutation
COUNT_MUTATION_RATE: float = 0.2  # probability of mutating bagger/truck counts
ELITE_COUNT: int = 2            # best N individuals carried unchanged to next gen

# Fitness penalty for a simulation that hits the 3 h hard timeout without
# finishing construction.  Must be larger than MAX_SIM_TIME so timeout
# individuals are always ranked worse than any completing run.
TIMEOUT_PENALTY: float = float(MAX_SIM_TIME) * 10.0

# Directory for output artefacts (best schedule, generation logs)
OUTPUT_DIR: str = "ga_results"

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

os.makedirs(OUTPUT_DIR, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(os.path.join(OUTPUT_DIR, "orchestrator.log")),
    ],
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Chromosome / Individual representation
# ---------------------------------------------------------------------------

@dataclass
class Individual:
    """
    One candidate solution (chromosome) in the genetic algorithm population.

    The chromosome encodes a complete agent-spawn schedule:
      - How many Baggers and Dirt Trucks to use (variable, within bounds).
      - The simulated-second at which each agent appears on site.
      - Material Trucks (2) and Crane (1) counts are fixed; only their spawn
        times are evolved.

    Fitness represents the simulated completion time in seconds.
    Lower fitness = faster construction = better solution.

    Attributes
    ----------
    num_baggers : int
        Number of Baggers to deploy (MIN_BAGGERS – MAX_BAGGERS).
    num_dirt_trucks : int
        Number of Dirt Trucks to deploy (MIN_DIRT_TRUCKS – MAX_DIRT_TRUCKS).
    bagger_spawns : List[int]
        Simulated-second timestamps at which each Bagger spawns.
        Length equals num_baggers.
    dirt_truck_spawns : List[int]
        Simulated-second timestamps at which each Dirt Truck spawns.
        Length equals num_dirt_trucks.
    material_truck_spawns : List[int]
        Spawn timestamps for the two fixed Material Trucks.
        Always exactly 2 elements.
    crane_spawn : int
        Spawn timestamp for the single fixed Crane.
    fitness : float | None
        Simulated completion time returned by the worker.
        None until evaluated.  Lower is better.
    """

    num_baggers: int
    num_dirt_trucks: int
    bagger_spawns: List[int]
    dirt_truck_spawns: List[int]
    material_truck_spawns: List[int]     # always length 2
    crane_spawn: int
    fitness: Optional[float] = field(default=None)

    # ------------------------------------------------------------------
    # Serialisation helpers
    # ------------------------------------------------------------------

    def to_schedule_dict(self) -> dict:
        """
        Convert the chromosome into the schedule dictionary expected by Godot.

        The dictionary maps *string* spawn-time keys to lists of agent-type
        strings.  Multiple agents sharing the same spawn time are grouped into
        the same list, preserving the format the Godot agent_spawner expects.

        Returns
        -------
        dict
            e.g. {"1": ["Bagger"], "60": ["DirtTruck", "Bagger"], ...}
        """
        schedule: dict[str, list[str]] = {}

        def add(time_sec: int, agent_type: str) -> None:
            key = str(time_sec)
            if key not in schedule:
                schedule[key] = []
            schedule[key].append(agent_type)

        for t in self.bagger_spawns:
            add(t, "Bagger")
        for t in self.dirt_truck_spawns:
            add(t, "DirtTruck")
        for t in self.material_truck_spawns:
            add(t, "MaterialTruck")
        add(self.crane_spawn, "Crane")

        return schedule

    def summary(self) -> str:
        """Human-readable one-liner for logging."""
        if self.fitness is not None:
            return (
                f"baggers={self.num_baggers} dirt_trucks={self.num_dirt_trucks} "
                f"fitness={self.fitness:.1f}s"
            )
        return (
            f"baggers={self.num_baggers} dirt_trucks={self.num_dirt_trucks} "
            f"fitness=<unevaluated>"
        )


# ---------------------------------------------------------------------------
# GA operators
# ---------------------------------------------------------------------------

def _random_spawn_times(count: int) -> List[int]:
    """
    Generate `count` random spawn times within [MIN_SPAWN_TIME, MAX_SPAWN_TIME].

    Parameters
    ----------
    count : int
        Number of spawn times to generate.

    Returns
    -------
    List[int]
        Sorted list of integer spawn times in seconds.
    """
    return sorted(random.randint(MIN_SPAWN_TIME, MAX_SPAWN_TIME)
                  for _ in range(count))


def random_individual() -> Individual:
    """
    Create a fully random Individual for population initialisation.

    Bagger and Dirt Truck counts are drawn uniformly from their valid ranges.
    Spawn times for all agents are drawn uniformly from [MIN_SPAWN_TIME, MAX_SPAWN_TIME].
    Material Trucks are always 2 and Crane is always 1 (problem constraints).

    Returns
    -------
    Individual
        A new, unevaluated Individual with random chromosome values.
    """
    n_baggers = random.randint(MIN_BAGGERS, MAX_BAGGERS)
    n_dirt_trucks = random.randint(MIN_DIRT_TRUCKS, MAX_DIRT_TRUCKS)
    return Individual(
        num_baggers=n_baggers,
        num_dirt_trucks=n_dirt_trucks,
        bagger_spawns=_random_spawn_times(n_baggers),
        dirt_truck_spawns=_random_spawn_times(n_dirt_trucks),
        material_truck_spawns=_random_spawn_times(MATERIAL_TRUCK_COUNT),
        crane_spawn=random.randint(MIN_SPAWN_TIME, MAX_SPAWN_TIME),
    )


def tournament_selection(population: List[Individual]) -> Individual:
    """
    Select one parent via tournament selection.

    TOURNAMENT_SIZE individuals are drawn at random from the population;
    the one with the lowest (best) fitness wins.  This operator maintains
    selection pressure while preserving diversity: weaker individuals can
    still win if stronger ones are absent from the tournament.

    Parameters
    ----------
    population : List[Individual]
        The current evaluated population.  All members must have fitness set.

    Returns
    -------
    Individual
        A deep copy of the winning individual (prevents aliasing in crossover).
    """
    contestants = random.sample(population, min(TOURNAMENT_SIZE, len(population)))
    winner = min(contestants, key=lambda ind: ind.fitness)  # lower = better
    return copy.deepcopy(winner)


def crossover(parent_a: Individual, parent_b: Individual) -> tuple[Individual, Individual]:
    """
    Produce two offspring via uniform crossover.

    Each gene is inherited from one of the two parents with equal probability.
    For variable-length spawn lists the child inherits the count from one
    parent and the spawn times are drawn from the combined (sorted) pool of
    both parents.  If the inherited count exceeds the available source times,
    new random times fill the gap.

    Crossover is only applied with probability CROSSOVER_PROBABILITY;
    otherwise the offspring are direct (deep) copies of the parents.

    Parameters
    ----------
    parent_a, parent_b : Individual
        Two parents selected from the population.

    Returns
    -------
    tuple[Individual, Individual]
        Two new offspring.  Fitness is reset to None.
    """
    if random.random() > CROSSOVER_PROBABILITY:
        child_a = copy.deepcopy(parent_a)
        child_b = copy.deepcopy(parent_b)
        child_a.fitness = None
        child_b.fitness = None
        return child_a, child_b

    def _cross_times(times_a: List[int], times_b: List[int],
                     target_count: int) -> List[int]:
        """
        Build a spawn-time list of length `target_count` from both parents.

        Strategy: merge and sort both parents' lists, then evenly subsample
        `target_count` elements.  If the merged pool is too small, pad with
        random times.
        """
        pool = sorted(times_a + times_b)
        if len(pool) >= target_count:
            step = len(pool) / target_count
            return sorted(pool[int(i * step)] for i in range(target_count))
        result = list(pool)
        while len(result) < target_count:
            result.append(random.randint(MIN_SPAWN_TIME, MAX_SPAWN_TIME))
        return sorted(result)

    # --- Agent counts: each child inherits from one parent ---
    n_baggers_a = parent_a.num_baggers if random.random() < 0.5 else parent_b.num_baggers
    n_baggers_b = parent_b.num_baggers if random.random() < 0.5 else parent_a.num_baggers
    n_dirt_a = parent_a.num_dirt_trucks if random.random() < 0.5 else parent_b.num_dirt_trucks
    n_dirt_b = parent_b.num_dirt_trucks if random.random() < 0.5 else parent_a.num_dirt_trucks

    child_a = Individual(
        num_baggers=n_baggers_a,
        num_dirt_trucks=n_dirt_a,
        bagger_spawns=_cross_times(parent_a.bagger_spawns, parent_b.bagger_spawns, n_baggers_a),
        dirt_truck_spawns=_cross_times(parent_a.dirt_truck_spawns, parent_b.dirt_truck_spawns, n_dirt_a),
        material_truck_spawns=_cross_times(
            parent_a.material_truck_spawns, parent_b.material_truck_spawns, MATERIAL_TRUCK_COUNT),
        crane_spawn=parent_a.crane_spawn if random.random() < 0.5 else parent_b.crane_spawn,
    )
    child_b = Individual(
        num_baggers=n_baggers_b,
        num_dirt_trucks=n_dirt_b,
        bagger_spawns=_cross_times(parent_a.bagger_spawns, parent_b.bagger_spawns, n_baggers_b),
        dirt_truck_spawns=_cross_times(parent_a.dirt_truck_spawns, parent_b.dirt_truck_spawns, n_dirt_b),
        material_truck_spawns=_cross_times(
            parent_a.material_truck_spawns, parent_b.material_truck_spawns, MATERIAL_TRUCK_COUNT),
        crane_spawn=parent_b.crane_spawn if random.random() < 0.5 else parent_a.crane_spawn,
    )
    return child_a, child_b


def mutate(individual: Individual) -> Individual:
    """
    Apply random mutations to an Individual in-place.

    Two classes of mutation are applied independently:

    **Count mutation** (probability COUNT_MUTATION_RATE per count gene):
        Increment or decrement the Bagger / Dirt Truck count by ±1, clamped
        to the valid range.  The spawn-time list is grown (with a new random
        time) or shrunk (by removing a random entry) accordingly.

    **Spawn-time mutation** (probability MUTATION_RATE per time gene):
        Add Gaussian noise (μ=0, σ=MUTATION_SIGMA seconds) to each spawn
        time, then clamp to [MIN_SPAWN_TIME, MAX_SPAWN_TIME].  This nudges
        agents earlier or later on the timeline.

    The Material Truck and Crane spawn times are also subject to time mutation
    (but their counts are never changed — they are fixed constraints).

    Parameters
    ----------
    individual : Individual
        The individual to mutate (modified in-place).

    Returns
    -------
    Individual
        The same individual (returned for convenience in chained calls).
    """

    def _mutate_count(current: int, lo: int, hi: int,
                      times: List[int]) -> tuple[int, List[int]]:
        """Mutate agent count and adjust the spawn list to match."""
        delta = random.choice([-1, 1])
        new_count = max(lo, min(hi, current + delta))
        new_times = list(times)
        if new_count > current:
            new_times.append(random.randint(MIN_SPAWN_TIME, MAX_SPAWN_TIME))
        elif new_count < current:
            new_times.pop(random.randrange(len(new_times)))
        return new_count, sorted(new_times)

    def _mutate_times(times: List[int]) -> List[int]:
        """Apply Gaussian perturbation to each spawn time with probability MUTATION_RATE."""
        result = []
        for t in times:
            if random.random() < MUTATION_RATE:
                t = int(t + random.gauss(0, MUTATION_SIGMA))
                t = max(MIN_SPAWN_TIME, min(MAX_SPAWN_TIME, t))
            result.append(t)
        return sorted(result)

    # Count mutations (baggers and dirt trucks only — material trucks and crane are fixed)
    if random.random() < COUNT_MUTATION_RATE:
        individual.num_baggers, individual.bagger_spawns = _mutate_count(
            individual.num_baggers, MIN_BAGGERS, MAX_BAGGERS, individual.bagger_spawns)

    if random.random() < COUNT_MUTATION_RATE:
        individual.num_dirt_trucks, individual.dirt_truck_spawns = _mutate_count(
            individual.num_dirt_trucks, MIN_DIRT_TRUCKS, MAX_DIRT_TRUCKS,
            individual.dirt_truck_spawns)

    # Spawn-time mutations for all agent types
    individual.bagger_spawns = _mutate_times(individual.bagger_spawns)
    individual.dirt_truck_spawns = _mutate_times(individual.dirt_truck_spawns)
    individual.material_truck_spawns = _mutate_times(individual.material_truck_spawns)

    if random.random() < MUTATION_RATE:
        individual.crane_spawn = max(
            MIN_SPAWN_TIME,
            min(MAX_SPAWN_TIME,
                int(individual.crane_spawn + random.gauss(0, MUTATION_SIGMA))))

    return individual


# ---------------------------------------------------------------------------
# Orchestrator — GA state + worker coordination
# ---------------------------------------------------------------------------

class GAOrchestrator:
    """
    Central coordinator: manages the population, task queue, and result collection.

    All public methods are safe to call from multiple threads concurrently —
    each acquires ``self.lock`` before touching shared state.

    Attributes
    ----------
    lock : threading.Lock
        Serialises all state mutations.
    population : List[Individual]
        The current generation's individuals (fitness populated after evaluation).
    current_generation : int
        Zero-based generation counter.
    pending_tasks : deque[tuple[int, Individual]]
        (task_id, individual) pairs waiting to be dispatched to workers.
    in_flight : dict[int, Individual]
        Dispatched tasks keyed by task_id; removed when the result arrives.
    generation_results : List[Individual]
        Evaluated individuals collected so far this generation.
    next_task_id : int
        Monotonically-increasing ID counter for tasks.
    finished : bool
        Set to True after all generations are complete.
    best_ever : Individual | None
        Best individual found across all generations.
    generation_history : List[dict]
        Per-generation statistics (best/avg/worst fitness).
    """

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.current_generation: int = 0
        self.pending_tasks: deque[tuple[int, Individual]] = deque()
        self.in_flight: dict[int, Individual] = {}
        self.generation_results: List[Individual] = []
        self.next_task_id: int = 0
        self.finished: bool = False
        self.best_ever: Optional[Individual] = None
        self.generation_history: List[dict] = []

        # Build the initial random population and queue it immediately
        log.info(
            "Initialising GA — population_size=%d  max_generations=%d  "
            "max_sim_time=%ds",
            POPULATION_SIZE, MAX_GENERATIONS, MAX_SIM_TIME,
        )
        self.population = [random_individual() for _ in range(POPULATION_SIZE)]
        self._enqueue_population(self.population)
        log.info("Generation 0 ready — %d tasks in queue", len(self.pending_tasks))

    # ------------------------------------------------------------------
    # Public interface (called by Flask route handlers)
    # ------------------------------------------------------------------

    def get_next_task(self) -> str:
        """
        Return a JSON task string, "wait", or "finished".

        The ``/input`` route calls this every time a worker polls for work.

        Returns
        -------
        str
            - JSON ``{"id": …, "schedule": {…}}``  →  worker runs a simulation.
            - ``"wait"``     →  generation in progress but queue is empty;
                                worker should retry after ~1 second.
            - ``"finished"`` →  all generations done; worker should exit.
        """
        with self.lock:
            if self.finished:
                return "finished"

            if not self.pending_tasks:
                # The generation is still running (some results outstanding).
                return "wait"

            task_id, individual = self.pending_tasks.popleft()
            self.in_flight[task_id] = individual

            payload = {
                "id": task_id,
                "schedule": individual.to_schedule_dict(),
            }
            log.debug("Dispatched  id=%-4d  gen=%-3d  %s",
                      task_id, self.current_generation, individual.summary())
            return json.dumps(payload)

    def submit_result(self, task_id: int, completion_time: float) -> str:
        """
        Record the result of one simulation run.

        The ``/handover`` route calls this.  When the last result of the
        current generation arrives, ``_evolve()`` is called automatically.

        Parameters
        ----------
        task_id : int
            The task ID that was given to the worker via ``/input``.
        completion_time : float
            Simulated seconds until construction finished.  A value at or near
            MAX_SIM_TIME indicates the simulation hit the hard timeout.

        Returns
        -------
        str
            ``"ok"`` or ``"unknown_task"``.
        """
        with self.lock:
            if task_id not in self.in_flight:
                log.warning("Handover for unknown task id=%d — ignored", task_id)
                return "unknown_task"

            individual = self.in_flight.pop(task_id)

            # Treat timeout completions as a heavy penalty so the GA avoids
            # schedules that leave the site unfinished within 3 hours.
            if completion_time >= MAX_SIM_TIME:
                individual.fitness = TIMEOUT_PENALTY
                log.info(
                    "Timeout  id=%-4d  gen=%-3d  "
                    "(penalised as %.0f)",
                    task_id, self.current_generation, TIMEOUT_PENALTY,
                )
            else:
                individual.fitness = completion_time
                log.info(
                    "Result   id=%-4d  gen=%-3d  time=%.1fs  "
                    "(%d/%d done)",
                    task_id, self.current_generation,
                    completion_time,
                    len(self.generation_results) + 1, POPULATION_SIZE,
                )

            self.generation_results.append(individual)

            # Trigger evolution once the full generation has been evaluated
            if len(self.generation_results) >= POPULATION_SIZE:
                self._evolve()

            return "ok"

    # ------------------------------------------------------------------
    # Internal helpers (called while holding self.lock)
    # ------------------------------------------------------------------

    def _enqueue_population(self, population: List[Individual]) -> None:
        """
        Reset fitness on every individual and add them to the pending-task deque.

        Parameters
        ----------
        population : List[Individual]
            Individuals to queue for evaluation.
        """
        for individual in population:
            individual.fitness = None
            task_id = self.next_task_id
            self.next_task_id += 1
            self.pending_tasks.append((task_id, individual))

    def _evolve(self) -> None:
        """
        Run one GA evolution step after a full generation has been evaluated.

        Called while ``self.lock`` is held, so no further locking is needed
        internally.  Must complete quickly to avoid starving request threads.

        Steps
        -----
        1. Collect results and compute per-generation statistics.
        2. Update the all-time best individual if a new best was found.
        3. Apply elitism: copy ELITE_COUNT best individuals to next generation.
        4. Fill remaining slots via tournament selection → crossover → mutation.
        5. Increment ``current_generation``.
        6. Either enqueue the next generation or set ``finished = True``.
        """
        evaluated = list(self.generation_results)
        self.generation_results.clear()

        # --- Generation statistics ---
        fitnesses = [ind.fitness for ind in evaluated]
        best_fitness = min(fitnesses)
        worst_fitness = max(fitnesses)
        avg_fitness = sum(fitnesses) / len(fitnesses)
        best_individual = min(evaluated, key=lambda ind: ind.fitness)

        log.info(
            "Gen %-3d  best=%8.1fs  avg=%8.1fs  worst=%8.1fs  | %s",
            self.current_generation,
            best_fitness, avg_fitness, worst_fitness,
            best_individual.summary(),
        )

        # --- All-time best tracking ---
        if self.best_ever is None or best_fitness < self.best_ever.fitness:
            self.best_ever = copy.deepcopy(best_individual)
            log.info(
                "*** New best in generation %d: %.1fs ***",
                self.current_generation, best_fitness,
            )
            self._save_best(self.best_ever)

        # --- History record ---
        self.generation_history.append({
            "generation": self.current_generation,
            "best_seconds": best_fitness,
            "average_seconds": avg_fitness,
            "worst_seconds": worst_fitness,
            "best_baggers": best_individual.num_baggers,
            "best_dirt_trucks": best_individual.num_dirt_trucks,
            "best_schedule": best_individual.to_schedule_dict(),
        })
        self._save_history()

        # --- Termination check ---
        self.current_generation += 1
        if self.current_generation >= MAX_GENERATIONS:
            log.info(
                "All %d generations complete.  Best overall: %.1fs",
                MAX_GENERATIONS, self.best_ever.fitness,
            )
            self.finished = True
            return

        # --- Build next generation ---
        # Sort ascending so index 0 is the best (lowest time)
        evaluated.sort(key=lambda ind: ind.fitness)

        next_gen: List[Individual] = []

        # Elitism: preserve the top ELITE_COUNT individuals unchanged
        for i in range(min(ELITE_COUNT, len(evaluated))):
            elite = copy.deepcopy(evaluated[i])
            elite.fitness = None   # will be re-evaluated next generation
            next_gen.append(elite)

        # Fill remaining slots via selection → crossover → mutation
        while len(next_gen) < POPULATION_SIZE:
            parent_a = tournament_selection(evaluated)
            parent_b = tournament_selection(evaluated)
            child_a, child_b = crossover(parent_a, parent_b)
            mutate(child_a)
            mutate(child_b)
            next_gen.append(child_a)
            if len(next_gen) < POPULATION_SIZE:
                next_gen.append(child_b)

        self.population = next_gen[:POPULATION_SIZE]
        self._enqueue_population(self.population)
        log.info(
            "Generation %d queued — %d tasks pending",
            self.current_generation, len(self.pending_tasks),
        )

    def _save_best(self, individual: Individual) -> None:
        """
        Persist the best schedule found so far as a JSON file.

        The file is overwritten each time a new best is discovered.

        Parameters
        ----------
        individual : Individual
            The best individual to serialise.
        """
        path = os.path.join(OUTPUT_DIR, "best_schedule.json")
        data = {
            "generation": self.current_generation - 1,
            "fitness_seconds": individual.fitness,
            "num_baggers": individual.num_baggers,
            "num_dirt_trucks": individual.num_dirt_trucks,
            "material_truck_count": MATERIAL_TRUCK_COUNT,
            "crane_count": CRANE_COUNT,
            "schedule": individual.to_schedule_dict(),
        }
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
        log.info("Best schedule saved → %s", path)

    def _save_history(self) -> None:
        """Overwrite the generation-history JSON with the latest data."""
        path = os.path.join(OUTPUT_DIR, "generation_history.json")
        with open(path, "w") as f:
            json.dump(self.generation_history, f, indent=2)


# ---------------------------------------------------------------------------
# Flask application
# ---------------------------------------------------------------------------

def create_app(orchestrator: GAOrchestrator) -> Flask:
    """
    Create and configure the Flask server application.

    Parameters
    ----------
    orchestrator : GAOrchestrator
        Shared orchestrator instance that owns all GA state.

    Returns
    -------
    Flask
        Configured and ready-to-run Flask application.
    """
    app = Flask(__name__)

    @app.route("/")
    def index() -> str:
        """Health-check: returns a one-page status summary."""
        with orchestrator.lock:
            return (
                f"GA Orchestrator running\n"
                f"Generation : {orchestrator.current_generation}/{MAX_GENERATIONS}\n"
                f"Pending    : {len(orchestrator.pending_tasks)}\n"
                f"In-flight  : {len(orchestrator.in_flight)}\n"
                f"Finished   : {orchestrator.finished}\n"
                + (f"Best so far: {orchestrator.best_ever.fitness:.1f}s\n"
                   if orchestrator.best_ever else "Best so far: none yet\n")
            )

    @app.route("/input")
    def input_handler() -> str:
        return json.dumps({
            "id": 0, "schedule": {"1": ["Bagger"],
                                  "60": ["DirtTruck"],
                                  "120": ["Bagger"],
                                  "180": ["DirtTruck"],
                                  "240": ["Bagger"],
                                  "300": ["DirtTruck"],
                                  "360": ["Bagger"],
                                  "420": ["DirtTruck"],
                                  "480": ["Bagger"],
                                  "540": ["DirtTruck"],
                                  "2": ["Bagger"],
                                  "61": ["DirtTruck"],
                                  "121": ["Bagger"],
                                  "181": ["DirtTruck"],
                                  "241": ["Bagger"],
                                  "301": ["DirtTruck"],
                                  "361": ["Bagger"],
                                  "421": ["DirtTruck"],
                                  "481": ["Bagger"],
                                  "541": ["DirtTruck"],
                                  "61": ["DirtTruck"],
                                  "121": ["Bagger"],
                                  "181": ["DirtTruck"],
                                  "241": ["Bagger"],
                                  "301": ["DirtTruck"],
                                  "361": ["Bagger"],
                                  "421": ["DirtTruck"],
                                  "481": ["Bagger"],
                                  "541": ["DirtTruck"],
                                  "741": ["Crane"],
                                  "741": ["MaterialTruck"],
                                  "741": ["MaterialTruck"]
                                  }})

        """
        Worker input endpoint — polled by each Godot instance every ~1 second.

        Returns one of:
          - JSON task payload  →  worker starts a simulation run
          - ``"wait"``         →  generation in progress; worker retries
          - ``"finished"``     →  all work done; worker shuts down
        """
        return orchestrator.get_next_task()

    @app.route("/handover")
    def handover_handler() -> str:
        """
        Worker output endpoint — called by Godot after each simulation.

        Query parameters
        ----------------
        id : str
            The integer task ID received from ``/input``.
        answer : str
            Simulated completion time in seconds (float).  At the 3 h limit
            when construction was not finished in time.

        Returns
        -------
        str
            ``"ok"`` on success, HTTP 400 on bad input, ``"unknown_task"``
            if the ID is unrecognised.
        """
        raw_id = request.args.get("id", "")
        raw_answer = request.args.get("answer", "")

        if not raw_id or not raw_answer:
            log.warning("/handover missing params — id=%r  answer=%r",
                        raw_id, raw_answer)
            return "bad_request", 400

        try:
            task_id = int(raw_id)
            completion_time = float(raw_answer)
        except ValueError:
            log.warning("/handover unparseable — id=%r  answer=%r",
                        raw_id, raw_answer)
            return "bad_request", 400

        return orchestrator.submit_result(task_id, completion_time)

    @app.route("/answers")
    def answers_handler() -> str:
        """Debug endpoint: last 5 generations of statistics."""
        with orchestrator.lock:
            lines = [
                f"Generation  : {orchestrator.current_generation}/{MAX_GENERATIONS}",
                f"Evaluated   : {len(orchestrator.generation_results)}/{POPULATION_SIZE}",
            ]
            if orchestrator.best_ever:
                lines.append(
                    f"Best ever   : {orchestrator.best_ever.fitness:.1f}s"
                )
            lines.append("")
            lines.append("Last 5 generations:")
            for entry in orchestrator.generation_history[-5:]:
                lines.append(
                    f"  gen {entry['generation']:3d}  "
                    f"best={entry['best_seconds']:8.1f}s  "
                    f"avg={entry['average_seconds']:8.1f}s  "
                    f"baggers={entry['best_baggers']}  "
                    f"dirt_trucks={entry['best_dirt_trucks']}"
                )
            return "\n".join(lines)

    return app


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    orchestrator = GAOrchestrator()
    app = create_app(orchestrator)

    log.info(
        "Server starting on port %d  "
        "(population=%d  generations=%d  workers=20  max_sim=%ds)",
        SERVER_PORT, POPULATION_SIZE, MAX_GENERATIONS, MAX_SIM_TIME,
    )

    # threaded=True lets Flask serve multiple concurrent workers simultaneously
    app.run(host="0.0.0.0", port=SERVER_PORT, threaded=True)
