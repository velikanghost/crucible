// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title The Crucible - Agent Battle Royale
/// @notice A trustless on-chain combat game where AI agents compete with real stakes.
///         Agents commit-reveal actions, earn points, propose rules, and fight for a prize pool.
contract Crucible {
    // ============ TYPES ============

    enum Action {
        NONE,
        DOMAIN,     // Beats Technique, loses to Counter  | Cost: 30
        TECHNIQUE,  // Beats Counter, loses to Domain     | Cost: 20
        COUNTER,    // Beats Domain, loses to Technique   | Cost: 10
        FLEE        // Escape combat                      | Cost: 5
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

    struct Matchup {
        address player1;
        address player2;
    }

    struct Commitment {
        bytes32 hash;
        Action action;
        bool committed;
        bool revealed;
    }

    struct Rule {
        RuleType ruleType;
        address proposer;
        uint256 activatedAtRound;
    }

    struct CombatResult {
        address player1;
        address player2;
        Action p1Action;
        Action p2Action;
        address winner;
        int256 pointsTransferred;
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

    Matchup[] public currentMatchups;
    mapping(uint256 => mapping(address => Commitment)) public commitments;

    Rule[] public activeRules;

    uint256 public prizePool;
    mapping(address => uint256) public pendingPayouts;

    // ============ EVENTS ============

    event PlayerRegistered(address indexed player);
    event GameStarted(uint256 playerCount, uint256 prizePool);
    event MatchupsSet(uint256 indexed round, uint256 commitDeadline, uint256 revealDeadline);
    event ActionCommitted(uint256 indexed round, address indexed player);
    event ActionRevealed(uint256 indexed round, address indexed player, Action action);
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
    error NoPayout();
    error TransferFailed();
    error SharesExceedTotal();
    error LengthMismatch();
    error PlayerNotAlive(address player);
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
        currentRound = 1;
        emit GameStarted(playerList.length, prizePool);
    }

    function setMatchups(
        Matchup[] calldata _matchups,
        uint256 _commitWindow,
        uint256 _revealWindow
    ) external onlyArbiter {
        if (phase == Phase.ENDED) revert GameNotActive();

        delete currentMatchups;
        for (uint256 i = 0; i < _matchups.length; i++) {
            if (!players[_matchups[i].player1].alive) revert PlayerNotAlive(_matchups[i].player1);
            if (!players[_matchups[i].player2].alive) revert PlayerNotAlive(_matchups[i].player2);
            currentMatchups.push(_matchups[i]);
        }

        phase = Phase.COMMIT;
        commitDeadline = block.timestamp + _commitWindow;
        revealDeadline = block.timestamp + _commitWindow + _revealWindow;

        emit MatchupsSet(currentRound, commitDeadline, revealDeadline);
    }

    // ============ COMBAT (Agents call directly) ============

    function commitAction(bytes32 _hash) external onlyRegistered inPhase(Phase.COMMIT) {
        if (block.timestamp >= commitDeadline) revert CommitWindowClosed();
        if (commitments[currentRound][msg.sender].committed) revert AlreadyCommitted();

        commitments[currentRound][msg.sender] = Commitment({
            hash: _hash,
            action: Action.NONE,
            committed: true,
            revealed: false
        });

        emit ActionCommitted(currentRound, msg.sender);
    }

    function revealAction(uint8 _action, bytes32 _salt) external onlyRegistered {
        if (block.timestamp < commitDeadline || block.timestamp >= revealDeadline) {
            revert NotInRevealWindow();
        }

        Commitment storage c = commitments[currentRound][msg.sender];
        if (!c.committed) revert NoCommitment();
        if (c.revealed) revert AlreadyRevealed();

        bytes32 expected = keccak256(abi.encodePacked(_action, _salt));
        if (expected != c.hash) revert HashMismatch();

        c.action = Action(_action);
        c.revealed = true;

        emit ActionRevealed(currentRound, msg.sender, Action(_action));
    }

    // ============ RESOLUTION (Arbiter triggers, logic is on-chain) ============

    function resolveRound() external onlyArbiter {
        if (block.timestamp < revealDeadline) revert RevealNotOver();

        for (uint256 i = 0; i < currentMatchups.length; i++) {
            _resolveCombat(currentMatchups[i]);
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
            pendingPayouts[_winners[i]] = (prizePool * _shares[i]) / 10000;
        }

        phase = Phase.ENDED;
        emit GameEnded(currentRound);
    }

    function claimRewards() external inPhase(Phase.ENDED) {
        uint256 payout = pendingPayouts[msg.sender];
        if (payout == 0) revert NoPayout();

        pendingPayouts[msg.sender] = 0;
        (bool sent,) = msg.sender.call{value: payout}("");
        if (!sent) revert TransferFailed();

        emit PayoutClaimed(msg.sender, payout);
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

    function getCurrentMatchups() external view returns (Matchup[] memory) {
        return currentMatchups;
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
        Action action
    ) {
        Commitment storage c = commitments[_round][_player];
        return (c.committed, c.revealed, c.action);
    }

    // ============ INTERNAL ============

    function _resolveCombat(Matchup memory m) internal {
        Commitment storage c1 = commitments[currentRound][m.player1];
        Commitment storage c2 = commitments[currentRound][m.player2];

        Action a1 = c1.revealed ? c1.action : Action.FLEE;
        Action a2 = c2.revealed ? c2.action : Action.FLEE;

        address winner;
        int256 transfer;

        if (a1 == Action.FLEE && a2 == Action.FLEE) {
            _deductCost(m.player1, _actionCost(Action.FLEE));
            _deductCost(m.player2, _actionCost(Action.FLEE));
        } else if (a1 == Action.FLEE) {
            _deductCost(m.player1, _actionCost(Action.FLEE));
            players[m.player2].points += 10;
            winner = m.player2;
            transfer = 10;
        } else if (a2 == Action.FLEE) {
            _deductCost(m.player2, _actionCost(Action.FLEE));
            players[m.player1].points += 10;
            winner = m.player1;
            transfer = 10;
        } else if (a1 == a2) {
            _deductCost(m.player1, _actionCost(a1));
            _deductCost(m.player2, _actionCost(a2));
        } else if (_beats(a1, a2)) {
            transfer = 10;
            players[m.player1].points += transfer - _actionCost(a1);
            players[m.player2].points -= transfer;
            winner = m.player1;
            _applyBloodTax(m.player1, transfer);
        } else {
            transfer = 10;
            players[m.player2].points += transfer - _actionCost(a2);
            players[m.player1].points -= transfer;
            winner = m.player2;
            _applyBloodTax(m.player2, transfer);
        }

        if (_isBountyTarget(m.player2) && winner == m.player1) {
            players[m.player1].points += transfer;
        }
        if (_isBountyTarget(m.player1) && winner == m.player2) {
            players[m.player2].points += transfer;
        }

        if (players[m.player1].points <= 0 && players[m.player1].alive) {
            players[m.player1].alive = false;
            emit PlayerEliminated(m.player1, currentRound);
        }
        if (players[m.player2].points <= 0 && players[m.player2].alive) {
            players[m.player2].alive = false;
            emit PlayerEliminated(m.player2, currentRound);
        }

        emit CombatResolved(
            currentRound,
            m.player1,
            m.player2,
            a1,
            a2,
            winner,
            transfer
        );
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
