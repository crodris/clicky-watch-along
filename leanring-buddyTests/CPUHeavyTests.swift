//
//  CPUHeavyTests.swift
//  leanring-buddyTests
//
//  The one lane for CPU-bound synchronous test suites.
//

import Testing

/// Swift Testing starts every test's clock when the run starts, not when the test begins. A synchronous suite that spends
/// seconds of CPU per test occupies every thread of the cooperative pool for the first 30 to 40 seconds of the run, and every
/// other test waits in the queue with its clock running. Its 60 second `.timeLimit` or 15 second `eventually` wait then
/// fails on whichever test is last in line, though its own body takes milliseconds.
///
/// A suite nested here runs one test at a time, and all the suites here share that one lane, so the rest of the run keeps its
/// threads. Add a new suite that is synchronous and spends several seconds of CPU with `extension CPUHeavyTests { ... }`.
/// `--experimental-maximum-parallelization-width` does not fix this, since the time a test waits for a width slot counts toward
/// its clock too.
@Suite(.serialized)
enum CPUHeavyTests {}
