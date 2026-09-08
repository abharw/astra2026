export interface TurnInput {
  userRequest: string;
  selectionNodeIds: string[];
}

export interface RecentTurn extends TurnInput {
  result: {
    status: "answered" | "installed" | "failed";
    explanation: string;
    affectedNodeIds: string[];
  };
}

/** Socket/scene-local history of terminal outcomes, never speculative proposals. */
export class SceneConversation {
  private turns: RecentTurn[] = [];
  static readonly maximumTurns = 6;
  static readonly maximumBytes = 12 * 1024;

  clear(): void { this.turns = []; }

  append(input: TurnInput, result: RecentTurn["result"]): void {
    const turn = structuredClone({ ...input, result });
    // Keep whole turns. A large request is omitted rather than silently truncated.
    if (Buffer.byteLength(JSON.stringify([turn]), "utf8") > SceneConversation.maximumBytes) return;
    this.turns.push(turn);
    while (this.turns.length > SceneConversation.maximumTurns || Buffer.byteLength(JSON.stringify(this.turns), "utf8") > SceneConversation.maximumBytes) this.turns.shift();
  }

  context(observedNodeIds: Set<string>): RecentTurn[] {
    return this.turns.map((turn) => ({
      ...turn,
      selectionNodeIds: turn.selectionNodeIds.filter((id) => observedNodeIds.has(id)),
      result: { ...turn.result, affectedNodeIds: turn.result.affectedNodeIds.filter((id) => observedNodeIds.has(id)) }
    }));
  }
}
