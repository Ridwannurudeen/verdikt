import { Case, Ruling, Party } from "../generated/schema";
import {
  CaseOpened,
  VerdictReached,
  Appealed,
  CaseFinalized,
} from "../generated/VerdiktCourt/VerdiktCourt";
import { RulingRecorded } from "../generated/VerdiktRegistry/VerdiktRegistry";
import { ReputationRecorded } from "../generated/VerdiktReputation/VerdiktReputation";

// --- Court lifecycle --------------------------------------------------------

export function handleCaseOpened(e: CaseOpened): void {
  let c = new Case(e.params.caseId.toString());
  c.consumer = e.params.consumer;
  c.escrowRef = e.params.escrowRef;
  c.status = "OPENED";
  c.round = 0;
  c.openedAt = e.block.timestamp;
  c.save();
}

export function handleVerdictReached(e: VerdictReached): void {
  let c = Case.load(e.params.caseId.toString());
  if (c == null) return;
  c.status = "RULED";
  c.verdict = e.params.verdict;
  c.round = e.params.round;
  c.receiptId = e.params.receiptId;
  c.ruledAt = e.block.timestamp;
  c.save();
}

export function handleAppealed(e: Appealed): void {
  let c = Case.load(e.params.caseId.toString());
  if (c == null) return;
  c.status = "APPEALED";
  c.round = e.params.newRound;
  c.save();
}

export function handleCaseFinalized(e: CaseFinalized): void {
  let c = Case.load(e.params.caseId.toString());
  if (c == null) return;
  c.status = "FINAL";
  c.verdict = e.params.verdict;
  c.finalizedAt = e.block.timestamp;
  c.save();
}

// --- Precedent registry -----------------------------------------------------

export function handleRulingRecorded(e: RulingRecorded): void {
  let r = new Ruling(e.params.caseId.toString());
  r.consumer = e.params.consumer;
  r.verdict = e.params.verdict;
  r.topic = e.params.topic;
  r.receiptId = e.params.receiptId;
  r.recordedAt = e.block.timestamp;
  r.save();
}

// --- Reputation -------------------------------------------------------------

export function handleReputationRecorded(e: ReputationRecorded): void {
  let id = e.params.party.toHexString();
  let p = Party.load(id);
  if (p == null) {
    p = new Party(id);
    p.disputes = 0;
    p.wins = 0;
    p.losses = 0;
    p.splits = 0;
  }
  p.disputes = p.disputes + 1;
  // verdict: 1 PAYEE, 2 PAYER, 3 SPLIT; side: 0 Payee, 1 Payer (mirrors VerdiktReputation._apply)
  let verdict = e.params.verdict;
  let side = e.params.side;
  if (verdict == 3) {
    p.splits = p.splits + 1;
  } else if ((verdict == 1 && side == 0) || (verdict == 2 && side == 1)) {
    p.wins = p.wins + 1;
  } else {
    p.losses = p.losses + 1;
  }
  p.lastCaseId = e.params.caseId;
  p.save();
}
