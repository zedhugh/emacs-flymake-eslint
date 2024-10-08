import type { ESLintMessage } from './message.mjs';

export interface WorkerInput {
  code: string;
  filepath: string;
}

export interface WorkerOutput {
  filepath: string;
  messages: ESLintMessage[];
}

export interface WorkerConfig {
  root: string;
  config: string;
}

export interface ESLintWorker {
  root: string;
  config: string;
  worker: Worker;
  files: Set<string>;
}
