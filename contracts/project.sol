// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// Governance Token for InfraDAO
contract InfraToken is ERC20, Ownable {
    uint256 public constant MAX_SUPPLY = 1000000 * 10**18; // 1M tokens
    
    constructor() ERC20("InfraDAO Token", "INFRA") {
        _mint(msg.sender, MAX_SUPPLY);
    }
    
    function mint(address to, uint256 amount) external onlyOwner {
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds max supply");
        _mint(to, amount);
    }
}

// Main DAO Contract
contract InfraDAO is ReentrancyGuard, Pausable, Ownable {
    InfraToken public immutable infraToken;
    
    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        string location;
        uint256 fundingAmount;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 createdAt;
        uint256 votingDeadline;
        bool executed;
        bool approved;
        ProposalStatus status;
        mapping(address => bool) hasVoted;
        mapping(address => uint256) voteWeight;
    }
    
    enum ProposalStatus {
        Active,
        Approved,
        Rejected,
        Executed,
        Cancelled
    }
    
    struct InfrastructureProject {
        uint256 proposalId;
        string projectType; // "road", "bridge", "water", "energy", etc.
        string location;
        uint256 estimatedCost;
        uint256 timelineMonths;
        address contractor;
        bool completed;
        uint256 completedAt;
    }
    
    // State variables
    uint256 public proposalCount;
    uint256 public constant VOTING_PERIOD = 7 days;
    uint256 public constant MINIMUM_TOKENS_TO_PROPOSE = 1000 * 10**18; // 1000 tokens
    uint256 public constant QUORUM_PERCENTAGE = 20; // 20% of total supply
    
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => InfrastructureProject) public projects;
    mapping(address => uint256) public memberTokens;
    mapping(address => bool) public isContractor;
    
    // Events
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        uint256 fundingAmount
    );
    
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        bool support,
        uint256 weight
    );
    
    event ProposalExecuted(
        uint256 indexed proposalId,
        bool approved,
        uint256 totalVotes
    );
    
    event ProjectStarted(
        uint256 indexed proposalId,
        address indexed contractor,
        uint256 fundingAmount
    );
    
    event ProjectCompleted(
        uint256 indexed proposalId,
        address indexed contractor
    );
    
    event FundsDeposited(address indexed depositor, uint256 amount);
    event FundsWithdrawn(uint256 indexed proposalId, uint256 amount);
    
    constructor(address _infraToken) {
        infraToken = InfraToken(_infraToken);
    }
    
    // Deposit ETH to DAO treasury
    receive() external payable {
        emit FundsDeposited(msg.sender, msg.value);
    }
    
    function depositFunds() external payable {
        emit FundsDeposited(msg.sender, msg.value);
    }
    
    // Create infrastructure proposal
    function createProposal(
        string memory _title,
        string memory _description,
        string memory _location,
        string memory _projectType,
        uint256 _fundingAmount,
        uint256 _timelineMonths
    ) external whenNotPaused {
        require(
            infraToken.balanceOf(msg.sender) >= MINIMUM_TOKENS_TO_PROPOSE,
            "Insufficient tokens to propose"
        );
        require(_fundingAmount > 0, "Funding amount must be positive");
        require(_fundingAmount <= address(this).balance, "Insufficient treasury funds");
        require(bytes(_title).length > 0, "Title cannot be empty");
        require(bytes(_description).length > 0, "Description cannot be empty");
        
        proposalCount++;
        uint256 proposalId = proposalCount;
        
        Proposal storage newProposal = proposals[proposalId];
        newProposal.id = proposalId;
        newProposal.proposer = msg.sender;
        newProposal.title = _title;
        newProposal.description = _description;
        newProposal.location = _location;
        newProposal.fundingAmount = _fundingAmount;
        newProposal.createdAt = block.timestamp;
        newProposal.votingDeadline = block.timestamp + VOTING_PERIOD;
        newProposal.status = ProposalStatus.Active;
        
        // Create associated project
        projects[proposalId] = InfrastructureProject({
            proposalId: proposalId,
            projectType: _projectType,
            location: _location,
            estimatedCost: _fundingAmount,
            timelineMonths: _timelineMonths,
            contractor: address(0),
            completed: false,
            completedAt: 0
        });
        
        emit ProposalCreated(proposalId, msg.sender, _title, _fundingAmount);
    }
    
    // Vote on proposal
    function vote(uint256 _proposalId, bool _support) external whenNotPaused {
        require(_proposalId <= proposalCount, "Invalid proposal ID");
        require(infraToken.balanceOf(msg.sender) > 0, "Must hold tokens to vote");
        
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.status == ProposalStatus.Active, "Proposal not active");
        require(block.timestamp <= proposal.votingDeadline, "Voting period ended");
        require(!proposal.hasVoted[msg.sender], "Already voted");
        
        uint256 voterTokens = infraToken.balanceOf(msg.sender);
        proposal.hasVoted[msg.sender] = true;
        proposal.voteWeight[msg.sender] = voterTokens;
        
        if (_support) {
            proposal.votesFor += voterTokens;
        } else {
            proposal.votesAgainst += voterTokens;
        }
        
        emit VoteCast(_proposalId, msg.sender, _support, voterTokens);
    }
    
    // Execute proposal after voting period
    function executeProposal(uint256 _proposalId) external whenNotPaused {
        require(_proposalId <= proposalCount, "Invalid proposal ID");
        
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.status == ProposalStatus.Active, "Proposal not active");
        require(block.timestamp > proposal.votingDeadline, "Voting still active");
        require(!proposal.executed, "Already executed");
        
        uint256 totalVotes = proposal.votesFor + proposal.votesAgainst;
        uint256 quorum = (infraToken.totalSupply() * QUORUM_PERCENTAGE) / 100;
        
        proposal.executed = true;
        
        if (totalVotes >= quorum && proposal.votesFor > proposal.votesAgainst) {
            proposal.approved = true;
            proposal.status = ProposalStatus.Approved;
        } else {
            proposal.approved = false;
            proposal.status = ProposalStatus.Rejected;
        }
        
        emit ProposalExecuted(_proposalId, proposal.approved, totalVotes);
    }
    
    // Assign contractor and start project
    function startProject(uint256 _proposalId, address _contractor) external onlyOwner {
        require(_proposalId <= proposalCount, "Invalid proposal ID");
        require(_contractor != address(0), "Invalid contractor address");
        require(isContractor[_contractor], "Address not registered as contractor");
        
        Proposal storage proposal = proposals[_proposalId];
        require(proposal.approved, "Proposal not approved");
        require(proposal.status == ProposalStatus.Approved, "Invalid status");
        
        InfrastructureProject storage project = projects[_proposalId];
        project.contractor = _contractor;
        
        // Transfer funds to contractor
        (bool success, ) = _contractor.call{value: proposal.fundingAmount}("");
        require(success, "Fund transfer failed");
        
        emit ProjectStarted(_proposalId, _contractor, proposal.fundingAmount);
        emit FundsWithdrawn(_proposalId, proposal.fundingAmount);
    }
    
    // Mark project as completed
    function completeProject(uint256 _proposalId) external {
        require(_proposalId <= proposalCount, "Invalid proposal ID");
        
        InfrastructureProject storage project = projects[_proposalId];
        Proposal storage proposal = proposals[_proposalId];
        
        require(
            msg.sender == project.contractor || msg.sender == owner(),
            "Only contractor or owner can mark complete"
        );
        require(project.contractor != address(0), "Project not started");
        require(!project.completed, "Already completed");
        
        project.completed = true;
        project.completedAt = block.timestamp;
        proposal.status = ProposalStatus.Executed;
        
        emit ProjectCompleted(_proposalId, project.contractor);
    }
    
    // Register/unregister contractors
    function setContractor(address _contractor, bool _status) external onlyOwner {
        isContractor[_contractor] = _status;
    }
    
    // View functions
    function getProposal(uint256 _proposalId) external view returns (
        uint256 id,
        address proposer,
        string memory title,
        string memory description,
        string memory location,
        uint256 fundingAmount,
        uint256 votesFor,
        uint256 votesAgainst,
        uint256 createdAt,
        uint256 votingDeadline,
        bool executed,
        bool approved,
        ProposalStatus status
    ) {
        require(_proposalId <= proposalCount, "Invalid proposal ID");
        Proposal storage proposal = proposals[_proposalId];
        
        return (
            proposal.id,
            proposal.proposer,
            proposal.title,
            proposal.description,
            proposal.location,
            proposal.fundingAmount,
            proposal.votesFor,
            proposal.votesAgainst,
            proposal.createdAt,
            proposal.votingDeadline,
            proposal.executed,
            proposal.approved,
            proposal.status
        );
    }
    
    function getProject(uint256 _proposalId) external view returns (
        uint256 proposalId,
        string memory projectType,
        string memory location,
        uint256 estimatedCost,
        uint256 timelineMonths,
        address contractor,
        bool completed,
        uint256 completedAt
    ) {
        require(_proposalId <= proposalCount, "Invalid proposal ID");
        InfrastructureProject storage project = projects[_proposalId];
        
        return (
            project.proposalId,
            project.projectType,
            project.location,
            project.estimatedCost,
            project.timelineMonths,
            project.contractor,
            project.completed,
            project.completedAt
        );
    }
    
    function hasVoted(uint256 _proposalId, address _voter) external view returns (bool) {
        return proposals[_proposalId].hasVoted[_voter];
    }
    
    function getVoteWeight(uint256 _proposalId, address _voter) external view returns (uint256) {
        return proposals[_proposalId].voteWeight[_voter];
    }
    
    function getTreasuryBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    function getQuorum() external view returns (uint256) {
        return (infraToken.totalSupply() * QUORUM_PERCENTAGE) / 100;
    }
    
    // Emergency functions
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function emergencyWithdraw(uint256 _amount) external onlyOwner {
        require(_amount <= address(this).balance, "Insufficient balance");
        (bool success, ) = owner().call{value: _amount}("");
        require(success, "Transfer failed");
    }
}
