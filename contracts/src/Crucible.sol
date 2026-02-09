// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title The Crucible - Agent Battle Royale
/// @notice A trustless on-chain free-for-all combat game where AI agents compete with real stakes.
///         Agents choose targets, commit-reveal actions, earn points, propose rules, and fight for a prize pool.
contract Crucible {
    // ============ TYPES ============

    enum Action {
        NONE,
        DOMAIN,     // Beats Technique, loses to Counter  | Cost: 30
        TECHNIQUE,  // Beats Counter, loses to Domain     | Cost: 20
        COUNTER,    // Beats Domain, loses to Technique   | Cost: 10
        FLEE        // Defensive — halves incoming damage  | Cost: 5
    }

    enum Phase {
        LOBBY,
        COMMIT,
        REVEAL,
        RULES,
        ENDED
    }

    enum RuleType {
        NONE,
        BLOOD_TAX,        // Rule creator gets 10% of all earned points
        BOUNTY_HUNTER,    // 2x points for defeating the leader
        EXPENSIVE_DOMAIN, // Domain costs 50 instead of 30
        SANCTUARY         // Skip next combat round (cooldown)
    }

    struct Player {
        int256 points;
        bool alive;
        bool registered;
    }

    struct Commitment {
        bytes32 hash;
        Action action;
        address target;
        bool committed;
        bool revealed;
    }

    struct Rule {
        RuleType ruleType;
        address proposer;
        uint256 activatedAtRound;
    }

    // ============ STATE ============

    address public arbiter;
    Phase public phase;
    uint256 public entryFee;
    int256 public startingPoints;
    uint256 public currentRound;
    uint256 public commitDeadline;
    uint256 public revealDeadline;

    mapping(address => Player) public players;
    address[] public playerList;

    mapping(uint256 => mapping(address => Commitment)) public commitments;

    Rule[] public activeRules;

    uint256 public prizePool;

    // ============ EVENTS ============

    event PlayerRegistered(address indexed player);
    event GameStarted(uint256 playerCount, uint256 prizePool);
    event RoundStarted(uint256 indexed round, uint256 commitDeadline, uint256 revealDeadline);
    event ActionCommitted(uint256 indexed round, address indexed player);
    event ActionRevealed(uint256 indexed round, address indexed player, Action action, address target);
    event CombatResolved(
        uint256 indexed round,
        address indexed player1,
        address indexed player2,
        Action p1Action,
        Action p2Action,
        address winner,
        int256 pointsTransferred
    );
    event PlayerEliminated(address indexed player, uint256 indexed round);
    event RuleProposed(address indexed proposer, RuleType ruleType);
    event RoundAdvanced(uint256 indexed round);
    event GameEnded(uint256 totalRounds);
    event PayoutClaimed(address indexed player, uint256 amount);
    event NewGame();

    // ============ ERRORS ============

    error OnlyArbiter();
    error WrongPhase(Phase expected, Phase actual);
    error WrongEntryFee(uint256 expected, uint256 sent);
    error AlreadyRegistered();
    error NotRegistered();
    error CommitWindowClosed();
    error AlreadyCommitted();
    error NotInRevealWindow();
    error NoCommitment();
    error AlreadyRevealed();
    error HashMismatch();
    error RevealNotOver();
    error InsufficientPoints();
    error NeedMorePlayers();
    error TransferFailed();
    error SharesExceedTotal();
    error LengthMismatch();
    error GameNotActive();

    // ============ MODIFIERS ============

    modifier onlyArbiter() {
        if (msg.sender != arbiter) revert OnlyArbiter();
        _;
    }

    modifier onlyRegistered() {
        if (!players[msg.sender].registered) revert NotRegistered();
        _;
    }

    modifier inPhase(Phase _phase) {
        if (phase != _phase) revert WrongPhase(_phase, phase);
        _;
    }

    // ============ CONSTRUCTOR ============

    constructor(address _arbiter, uint256 _entryFee, int256 _startingPoints) {
        arbiter = _arbiter;
        entryFee = _entryFee;
        startingPoints = _startingPoints;
        phase = Phase.LOBBY;
    }

    // ============ REGISTRATION ============

    function register() external payable inPhase(Phase.LOBBY) {
        if (msg.value != entryFee) revert WrongEntryFee(entryFee, msg.value);
        if (players[msg.sender].registered) revert AlreadyRegistered();

        players[msg.sender] = Player({
            points: startingPoints,
            alive: true,
            registered: true
        });
        playerList.push(msg.sender);
        prizePool += msg.value;

        emit PlayerRegistered(msg.sender);
    }

    // ============ ROUND MANAGEMENT (Arbiter) ============

    function startGame() external onlyArbiter inPhase(Phase.LOBBY) {
        if (playerList.length < 2) revert NeedMorePlayers();
        currentRound++;
        emit GameStarted(playerList.length, prizePool);
    }

    function startRound(
        uint256 _commitWindow,
        uint256 _revealWindow
    ) external onlyArbiter {
        if (phase == Phase.ENDED) revert GameNotActive();

        phase = Phase.COMMIT;
        commitDeadline = block.timestamp + _commitWindow;
        revealDeadline = block.timestamp + _commitWindow + _revealWindow;

        emit RoundStarted(currentRound, commitDeadline, revealDeadline);
    }

    // ============ COMBAT (Agents call directly) ============

    function commitAction(bytes32 _hash) external onlyRegistered inPhase(Phase.COMMIT) {
        if (block.timestamp >= commitDeadline) revert CommitWindowClosed();
        if (commitments[currentRound][msg.sender].committed) revert AlreadyCommitted();

        commitments[currentRound][msg.sender] = Commitment({
            hash: _hash,
            action: Action.NONE,
            target: address(0),
            committed: true,
            revealed: false
        });

        emit ActionCommitted(currentRound, msg.sender);
    }

    function revealAction(uint8 _action, address _target, bytes32 _salt) external onlyRegistered {
        if (block.timestamp < commitDeadline || block.timestamp >= revealDeadline) {
            revert NotInRevealWindow();
        }

        Commitment storage c = commitments[currentRound][msg.sender];
        if (!c.committed) revert NoCommitment();
        if (c.revealed) revert AlreadyRevealed();

        bytes32 expected = keccak256(abi.encodePacked(_action, _target, _salt));
        if (expected != c.hash) revert HashMismatch();

        c.action = Action(_action);
        c.target = _target;
        c.revealed = true;

        emit ActionRevealed(currentRound, msg.sender, Action(_action), _target);
    }

    // ============ RESOLUTION (Arbiter triggers, logic is on-chain) ============

    function resolveRound() external onlyArbiter {
        if (block.timestamp < revealDeadline) revert RevealNotOver();

        uint256 len = playerList.length;

        // Build action/target arrays in memory for efficient access
        Action[] memory actions = new Action[](len);
        address[] memory targets = new address[](len);

        for (uint256 i = 0; i < len; i++) {
            if (!players[playerList[i]].alive) continue;
            Commitment storage c = commitments[currentRound][playerList[i]];
            actions[i] = c.revealed ? c.action : Action.FLEE;
            targets[i] = c.revealed ? c.target : address(0);
        }

        // Process each alive player's action
        for (uint256 i = 0; i < len; i++) {
            if (!players[playerList[i]].alive) continue;

            // Flee or no valid target: pay flee cost only
            if (actions[i] == Action.FLEE || targets[i] == address(0) || targets[i] == playerList[i]) {
                _deductCost(playerList[i], _actionCost(Action.FLEE));
                continue;
            }

            // Target is dead: pay action cost, no damage
            if (!players[targets[i]].alive) {
                _deductCost(playerList[i], _actionCost(actions[i]));
                continue;
            }

            // Find target's index in playerList
            uint256 targetIdx = _playerIndex(targets[i], len);

            // Check for mutual combat (both target each other)
            bool isMutual = targets[targetIdx] == playerList[i];

            if (isMutual && i < targetIdx) {
                // Process mutual combat once (lower index handles it)
                _resolveMutualCombat(playerList[i], playerList[targetIdx], actions[i], actions[targetIdx]);
            } else if (isMutual) {
                // Already processed by lower index — skip
                continue;
            } else {
                // One-way attack (target is fighting someone else)
                _resolveOneWayAttack(playerList[i], targets[i], actions[i], actions[targetIdx]);
            }
        }

        // Elimination check (deferred so point changes from all combats are applied first)
        for (uint256 i = 0; i < len; i++) {
            if (players[playerList[i]].points <= 0 && players[playerList[i]].alive) {
                players[playerList[i]].alive = false;
                emit PlayerEliminated(playerList[i], currentRound);
            }
        }

        phase = Phase.RULES;
    }

    // ============ RULES ============

    function proposeRule(RuleType _ruleType) external onlyRegistered inPhase(Phase.RULES) {
        if (players[msg.sender].points < 100) revert InsufficientPoints();

        players[msg.sender].points -= 100;
        activeRules.push(Rule({
            ruleType: _ruleType,
            proposer: msg.sender,
            activatedAtRound: currentRound
        }));

        emit RuleProposed(msg.sender, _ruleType);
    }

    function advanceRound() external onlyArbiter inPhase(Phase.RULES) {
        currentRound++;
        emit RoundAdvanced(currentRound);
    }

    // ============ SETTLEMENT ============

    function endGame(
        address[] calldata _winners,
        uint256[] calldata _shares
    ) external onlyArbiter {
        if (_winners.length != _shares.length) revert LengthMismatch();

        uint256 totalShares;
        for (uint256 i = 0; i < _shares.length; i++) {
            totalShares += _shares[i];
        }
        if (totalShares > 10000) revert SharesExceedTotal();

        for (uint256 i = 0; i < _winners.length; i++) {
            uint256 payout = (prizePool * _shares[i]) / 10000;
            if (payout > 0) {
                (bool sent,) = _winners[i].call{value: payout}("");
                if (!sent) revert TransferFailed();
                emit PayoutClaimed(_winners[i], payout);
            }
        }

        phase = Phase.ENDED;
        emit GameEnded(currentRound);
    }

    // ============ NEW GAME ============

    function newGame() external onlyArbiter inPhase(Phase.ENDED) {
        for (uint256 i = 0; i < playerList.length; i++) {
            delete players[playerList[i]];
        }
        delete playerList;
        delete activeRules;

        commitDeadline = 0;
        revealDeadline = 0;
        prizePool = 0;
        phase = Phase.LOBBY;

        emit NewGame();
    }

    // ============ VIEW FUNCTIONS ============

    function getPlayerCount() external view returns (uint256) {
        return playerList.length;
    }

    function getAliveCount() external view returns (uint256 count) {
        for (uint256 i = 0; i < playerList.length; i++) {
            if (players[playerList[i]].alive) count++;
        }
    }

    function getAlivePlayers() external view returns (address[] memory) {
        uint256 count;
        for (uint256 i = 0; i < playerList.length; i++) {
            if (players[playerList[i]].alive) count++;
        }

        address[] memory alive = new address[](count);
        uint256 idx;
        for (uint256 i = 0; i < playerList.length; i++) {
            if (players[playerList[i]].alive) {
                alive[idx] = playerList[i];
                idx++;
            }
        }
        return alive;
    }

    function getActiveRules() external view returns (Rule[] memory) {
        return activeRules;
    }

    function getPlayerInfo(address _player) external view returns (
        int256 points,
        bool alive,
        bool registered
    ) {
        Player storage p = players[_player];
        return (p.points, p.alive, p.registered);
    }

    function getCommitment(uint256 _round, address _player) external view returns (
        bool committed,
        bool revealed,
        Action action,
        address target
    ) {
        Commitment storage c = commitments[_round][_player];
        return (c.committed, c.revealed, c.action, c.target);
    }

    // ============ INTERNAL ============

    function _resolveMutualCombat(
        address p1,
        address p2,
        Action a1,
        Action a2
    ) internal {
        address winner;
        int256 transfer;

        if (a1 == Action.FLEE && a2 == Action.FLEE) {
            _deductCost(p1, _actionCost(Action.FLEE));
            _deductCost(p2, _actionCost(Action.FLEE));
        } else if (a1 == Action.FLEE) {
            _deductCost(p1, _actionCost(Action.FLEE));
            transfer = 15;
            players[p2].points += transfer - _actionCost(a2);
            players[p1].points -= transfer;
            winner = p2;
            _applyBloodTax(p2, transfer);
        } else if (a2 == Action.FLEE) {
            _deductCost(p2, _actionCost(Action.FLEE));
            transfer = 15;
            players[p1].points += transfer - _actionCost(a1);
            players[p2].points -= transfer;
            winner = p1;
            _applyBloodTax(p1, transfer);
        } else if (a1 == a2) {
            _deductCost(p1, _actionCost(a1));
            _deductCost(p2, _actionCost(a2));
        } else if (_beats(a1, a2)) {
            transfer = 15;
            players[p1].points += transfer - _actionCost(a1);
            players[p2].points -= transfer;
            winner = p1;
            _applyBloodTax(p1, transfer);
        } else {
            transfer = 15;
            players[p2].points += transfer - _actionCost(a2);
            players[p1].points -= transfer;
            winner = p2;
            _applyBloodTax(p2, transfer);
        }

        // Bounty hunter bonus
        if (_isBountyTarget(p2) && winner == p1) {
            players[p1].points += transfer;
        }
        if (_isBountyTarget(p1) && winner == p2) {
            players[p2].points += transfer;
        }

        emit CombatResolved(currentRound, p1, p2, a1, a2, winner, transfer);
    }

    function _resolveOneWayAttack(
        address attacker,
        address target,
        Action attackAction,
        Action targetAction
    ) internal {
        _deductCost(attacker, _actionCost(attackAction));

        int256 damage = 10;
        if (targetAction == Action.FLEE) {
            damage = 5;
        }

        players[target].points -= damage;

        emit CombatResolved(currentRound, attacker, target, attackAction, targetAction, attacker, damage);
    }

    function _playerIndex(address player, uint256 len) internal view returns (uint256) {
        for (uint256 i = 0; i < len; i++) {
            if (playerList[i] == player) return i;
        }
        return len;
    }

    function _beats(Action a, Action b) internal pure returns (bool) {
        return
            (a == Action.DOMAIN && b == Action.TECHNIQUE) ||
            (a == Action.TECHNIQUE && b == Action.COUNTER) ||
            (a == Action.COUNTER && b == Action.DOMAIN);
    }

    function _actionCost(Action a) internal view returns (int256) {
        if (a == Action.DOMAIN) {
            return _hasRule(RuleType.EXPENSIVE_DOMAIN) ? int256(50) : int256(30);
        }
        if (a == Action.TECHNIQUE) return 20;
        if (a == Action.COUNTER) return 10;
        return 5; // FLEE
    }

    function _deductCost(address player, int256 cost) internal {
        players[player].points -= cost;
    }

    function _hasRule(RuleType rt) internal view returns (bool) {
        for (uint256 i = 0; i < activeRules.length; i++) {
            if (activeRules[i].ruleType == rt) return true;
        }
        return false;
    }

    function _applyBloodTax(address winner, int256 pointsEarned) internal {
        for (uint256 i = 0; i < activeRules.length; i++) {
            if (activeRules[i].ruleType == RuleType.BLOOD_TAX) {
                int256 tax = pointsEarned / 10;
                players[winner].points -= tax;
                players[activeRules[i].proposer].points += tax;
            }
        }
    }

    function _isBountyTarget(address player) internal view returns (bool) {
        if (!_hasRule(RuleType.BOUNTY_HUNTER)) return false;

        int256 maxPoints = type(int256).min;
        address leader;
        for (uint256 i = 0; i < playerList.length; i++) {
            if (players[playerList[i]].alive && players[playerList[i]].points > maxPoints) {
                maxPoints = players[playerList[i]].points;
                leader = playerList[i];
            }
        }
        return player == leader;
    }
}
