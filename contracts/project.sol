// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract InfraDAO is ERC20, Ownable, ReentrancyGuard {
    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        uint256 amount; // Amount requested from treasury
        address payable recipient;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 endTime;
        bool executed;
        bool exists;
    }

    struct Vote {
        bool hasVoted;
        bool support;
        uint256 weight;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => Vote)) public votes;
    mapping(address => bool) public members;
    
    uint256 public proposalCount;
    uint256 public constant VOTING_PERIOD = 7 days;
    uint256 public constant PROPOSAL_THRESHOLD = 1000 * 10**18; // 1000 tokens to propose
    uint256 public constant QUORUM = 51; // 51% quorum required
    uint256 public treasury;

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        uint256 amount
    );
    
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        bool support,
        uint256 weight
    );
    
    event ProposalExecuted(uint256 indexed proposalId, bool success);
    event MemberAdded(address indexed member);
    event FundsDeposited(address indexed depositor, uint256 amount);

    modifier onlyMember() {
        require(members[msg.sender], "Not a DAO member");
        _;
    }

    modifier proposalExists(uint256 _proposalId) {
        require(proposals[_proposalId].exists, "Proposal does not exist");
        _;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _initialSupply
    ) ERC20(_name, _symbol) {
        _mint(msg.sender, _initialSupply);
        members[msg.sender] = true;
        emit MemberAdded(msg.sender);
    }

    // Add member to DAO
    function addMember(address _member) external onlyOwner {
        members[_member] = true;
        emit MemberAdded(_member);
    }

    // Deposit funds to treasury
    function depositToTreasury() external payable {
        treasury += msg.value;
        emit FundsDeposited(msg.sender, msg.value);
    }

    // Create a new proposal
    function createProposal(
        string memory _title,
        string memory _description,
        uint256 _amount,
        address payable _recipient
    ) external onlyMember returns (uint256) {
        require(balanceOf(msg.sender) >= PROPOSAL_THRESHOLD, "Insufficient tokens to propose");
        require(_amount <= treasury, "Requested amount exceeds treasury");

        proposalCount++;
        
        proposals[proposalCount] = Proposal({
            id: proposalCount,
            proposer: msg.sender,
            title: _title,
            description: _description,
            amount: _amount,
            recipient: _recipient,
            votesFor: 0,
            votesAgainst: 0,
            endTime: block.timestamp + VOTING_PERIOD,
            executed: false,
            exists: true
        });

        emit ProposalCreated(proposalCount, msg.sender, _title, _amount);
        return proposalCount;
    }

    // Vote on a proposal
    function vote(uint256 _proposalId, bool _support) 
        external 
        onlyMember 
        proposalExists(_proposalId) 
    {
        Proposal storage proposal = proposals[_proposalId];
        require(block.timestamp < proposal.endTime, "Voting period has ended");
        require(!votes[_proposalId][msg.sender].hasVoted, "Already voted");

        uint256 voterWeight = balanceOf(msg.sender);
        require(voterWeight > 0, "No voting power");

        votes[_proposalId][msg.sender] = Vote({
            hasVoted: true,
            support: _support,
            weight: voterWeight
        });

        if (_support) {
            proposal.votesFor += voterWeight;
        } else {
            proposal.votesAgainst += voterWeight;
        }

        emit VoteCast(_proposalId, msg.sender, _support, voterWeight);
    }

    // Execute a proposal if it has passed
    function executeProposal(uint256 _proposalId) 
        external 
        proposalExists(_proposalId) 
        nonReentrant 
    {
        Proposal storage proposal = proposals[_proposalId];
        require(block.timestamp >= proposal.endTime, "Voting still in progress");
        require(!proposal.executed, "Proposal already executed");

        uint256 totalVotes = proposal.votesFor + proposal.votesAgainst;
        uint256 totalSupply = totalSupply();
        
        // Check if quorum is met and proposal passed
        bool quorumMet = (totalVotes * 100) / totalSupply >= QUORUM;
        bool proposalPassed = proposal.votesFor > proposal.votesAgainst;
        
        proposal.executed = true;
        
        if (quorumMet && proposalPassed) {
            treasury -= proposal.amount;
            proposal.recipient.transfer(proposal.amount);
            emit ProposalExecuted(_proposalId, true);
        } else {
            emit ProposalExecuted(_proposalId, false);
        }
    }

    // Get proposal details
    function getProposal(uint256 _proposalId) 
        external 
        view 
        proposalExists(_proposalId) 
        returns (
            uint256 id,
            address proposer,
            string memory title,
            string memory description,
            uint256 amount,
            address recipient,
            uint256 votesFor,
            uint256 votesAgainst,
            uint256 endTime,
            bool executed
        ) 
    {
        Proposal storage proposal = proposals[_proposalId];
        return (
            proposal.id,
            proposal.proposer,
            proposal.title,
            proposal.description,
            proposal.amount,
            proposal.recipient,
            proposal.votesFor,
            proposal.votesAgainst,
            proposal.endTime,
            proposal.executed
        );
    }

    // Check if proposal has reached quorum and passed
    function getProposalStatus(uint256 _proposalId) 
        external 
        view 
        proposalExists(_proposalId) 
        returns (bool quorumMet, bool passed, bool canExecute) 
    {
        Proposal storage proposal = proposals[_proposalId];
        uint256 totalVotes = proposal.votesFor + proposal.votesAgainst;
        uint256 supply = totalSupply();
        
        quorumMet = (totalVotes * 100) / supply >= QUORUM;
        passed = proposal.votesFor > proposal.votesAgainst;
        canExecute = block.timestamp >= proposal.endTime && !proposal.executed;
    }

    // Get treasury balance
    function getTreasuryBalance() external view returns (uint256) {
        return treasury;
    }

    // Override transfer to update membership
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool result = super.transfer(to, amount);
        if (result && balanceOf(to) > 0 && !members[to]) {
            members[to] = true;
            emit MemberAdded(to);
        }
        return result;
    }

    // Emergency withdrawal (only owner)
    function emergencyWithdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    // Receive function to accept ETH
    receive() external payable {
        treasury += msg.value;
        emit FundsDeposited(msg.sender, msg.value);
    }
}
