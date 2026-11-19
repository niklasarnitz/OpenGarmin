// What the dashboard measures. A concept is one quantity that Garmin and Apple Health may both record. Garmin's
// own metric name comes first, then the HealthKit identifier, so the same series can come from either source.
// `scale` converts a key's stored unit to the concept's unit.

export type ConceptId =
  | "steps"
  | "activeEnergy"
  | "intensityMinutes"
  | "restingHeartRate"
  | "hrv"
  | "stress"
  | "bodyBattery"
  | "sleepMinutes"
  | "spo2"
  | "respiration"
  | "distance"
  | "floors"
  | "exerciseMinutes"
  | "weight"
  | "bodyFat"
  | "wristTemperature";

export interface Concept {
  id: ConceptId;
  keys: readonly string[];
  /** Factor per key from its stored unit to `unit`; 1 when absent. */
  scale?: Readonly<Record<string, number>>;
  unit: string;
  agg: "sum" | "avg";
  decimals: number;
  /** The healthier direction, used to colour a change. Null when neither direction is better. */
  higherIsBetter: boolean | null;
}

export const CONCEPTS: Record<ConceptId, Concept> = {
  steps: { id: "steps", keys: ["steps", "HKQuantityTypeIdentifierStepCount"], unit: "", agg: "sum", decimals: 0, higherIsBetter: true },
  activeEnergy: {
    id: "activeEnergy",
    keys: ["activeEnergy", "HKQuantityTypeIdentifierActiveEnergyBurned"],
    unit: "kcal",
    agg: "sum",
    decimals: 0,
    higherIsBetter: true,
  },
  intensityMinutes: { id: "intensityMinutes", keys: ["intensityMinutes"], unit: "min", agg: "sum", decimals: 0, higherIsBetter: true },
  restingHeartRate: {
    id: "restingHeartRate",
    keys: ["restingHeartRate", "HKQuantityTypeIdentifierRestingHeartRate"],
    unit: "bpm",
    agg: "avg",
    decimals: 1,
    higherIsBetter: false,
  },
  hrv: { id: "hrv", keys: ["hrv", "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"], unit: "ms", agg: "avg", decimals: 0, higherIsBetter: true },
  stress: { id: "stress", keys: ["stress"], unit: "", agg: "avg", decimals: 0, higherIsBetter: false },
  bodyBattery: { id: "bodyBattery", keys: ["bodyBattery"], unit: "", agg: "avg", decimals: 0, higherIsBetter: true },
  sleepMinutes: { id: "sleepMinutes", keys: ["sleepMinutes"], unit: "min", agg: "sum", decimals: 0, higherIsBetter: true },
  // Both store a fraction (0.96).
  spo2: {
    id: "spo2",
    keys: ["spo2", "HKQuantityTypeIdentifierOxygenSaturation"],
    scale: { spo2: 100, HKQuantityTypeIdentifierOxygenSaturation: 100 },
    unit: "%",
    agg: "avg",
    decimals: 1,
    higherIsBetter: true,
  },
  respiration: {
    id: "respiration",
    keys: ["respiration", "HKQuantityTypeIdentifierRespiratoryRate"],
    unit: "brpm",
    agg: "avg",
    decimals: 1,
    higherIsBetter: null,
  },
  // Garmin stores metres, Apple Health the phone's preferred unit (km).
  distance: {
    id: "distance",
    keys: ["distance", "HKQuantityTypeIdentifierDistanceWalkingRunning"],
    scale: { distance: 0.001 },
    unit: "km",
    agg: "sum",
    decimals: 1,
    higherIsBetter: true,
  },
  floors: { id: "floors", keys: ["floors", "HKQuantityTypeIdentifierFlightsClimbed"], unit: "", agg: "sum", decimals: 0, higherIsBetter: true },
  exerciseMinutes: {
    id: "exerciseMinutes",
    keys: ["HKQuantityTypeIdentifierAppleExerciseTime"],
    unit: "min",
    agg: "sum",
    decimals: 0,
    higherIsBetter: true,
  },
  weight: { id: "weight", keys: ["HKQuantityTypeIdentifierBodyMass"], unit: "kg", agg: "avg", decimals: 1, higherIsBetter: null },
  bodyFat: { id: "bodyFat", keys: ["HKQuantityTypeIdentifierBodyFatPercentage"], unit: "%", agg: "avg", decimals: 1, higherIsBetter: false },
  wristTemperature: {
    id: "wristTemperature",
    keys: ["HKQuantityTypeIdentifierAppleSleepingWristTemperature"],
    unit: "°C",
    agg: "avg",
    decimals: 2,
    higherIsBetter: null,
  },
};

export const CONCEPT_IDS = Object.keys(CONCEPTS) as ConceptId[];

const conceptByKey = new Map<string, ConceptId>(
  CONCEPT_IDS.flatMap((id) => CONCEPTS[id].keys.map((key) => [key, id] as [string, ConceptId])),
);

export function conceptOf(metricKey: string): ConceptId | undefined {
  return conceptByKey.get(metricKey);
}
