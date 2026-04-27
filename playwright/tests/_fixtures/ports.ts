export const BASE_PORT = 8080;
export const PORTS_PER_WORKER = 100;

export interface PortAllocation {
  workerIndex: number;
  fixtureIndex: number;
}

export function allocatePort({ workerIndex, fixtureIndex }: PortAllocation): number {
  if (fixtureIndex < 0 || fixtureIndex >= PORTS_PER_WORKER) {
    throw new RangeError(
      `fixtureIndex ${fixtureIndex} must be < PORTS_PER_WORKER (${PORTS_PER_WORKER})`,
    );
  }
  if (workerIndex < 0) {
    throw new RangeError(`workerIndex ${workerIndex} must be >= 0`);
  }
  return BASE_PORT + workerIndex * PORTS_PER_WORKER + fixtureIndex;
}
