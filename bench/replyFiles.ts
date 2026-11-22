// The files `bench.ts worker --pages-dir <dir>` writes and `judge.ts` reads.
//
//   <dir>/<side>-<case>-<run>.json   one reply, with the side that gave it and the checks it got
//   <dir>/requests/<case>.json       the request body a case sends, written once

export type SavedReply = {
  /** The --side label, such as parts-sol61. The judge keeps it out of what the judging model reads. */
  side: string;
  caseId: string;
  route: string;
  /** Counted from 0, as in the result file. */
  runIndex: number;
  httpStatus: number;
  qualityPassed: boolean;
  /** The models the Worker's usage lines named. A /chat reply names the one in its stream. */
  models: string[];
  /** The whole reply text. A /chat reply is the streamed text joined. */
  replyText: string;
};

export function savedReplyFileName(side: string, caseId: string, runIndex: number): string {
  return `${side}-${caseId}-${runIndex + 1}.json`;
}

export function requestFileName(caseId: string): string {
  return `requests/${caseId}.json`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Undefined for a file that is not a saved reply, such as a live scene's .html page or the requests folder. */
export function parseSavedReply(fileValue: unknown): SavedReply | undefined {
  if (
    !isRecord(fileValue) ||
    typeof fileValue.side !== "string" ||
    typeof fileValue.caseId !== "string" ||
    typeof fileValue.route !== "string" ||
    typeof fileValue.runIndex !== "number" ||
    typeof fileValue.httpStatus !== "number" ||
    typeof fileValue.qualityPassed !== "boolean" ||
    !Array.isArray(fileValue.models) ||
    typeof fileValue.replyText !== "string"
  ) {
    return undefined;
  }
  return {
    side: fileValue.side,
    caseId: fileValue.caseId,
    route: fileValue.route,
    runIndex: fileValue.runIndex,
    httpStatus: fileValue.httpStatus,
    qualityPassed: fileValue.qualityPassed,
    models: fileValue.models.filter((modelName): modelName is string => typeof modelName === "string"),
    replyText: fileValue.replyText,
  };
}
