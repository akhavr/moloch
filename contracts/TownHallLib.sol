pragma solidity 0.4.23;

import "zeppelin-solidity/contracts/ownership/Ownable.sol";
import "./VotingLib.sol";
import "./VotingShares.sol";
import "./Moloch.sol";
import "./GuildBank.sol";
import "./LootToken.sol";
import "zeppelin-solidity/contracts/token/ERC20/ERC20.sol";

library TownHallLib {
    using VotingLib for VotingLib.Ballot;

    /*****
    EVENTS
    *****/
    event ProposalCreated(
        address indexed proposer,
        uint256 votingSharesRequested,
        ProposalTypes proposalType,
        uint indexInProposalQueue
    );

    event ProposalVotingStarted(
        uint indexed indexInProposalQueue
    );

    event ProposalGracePeriodStarted(
        uint indexed indexInProposalQueue
    );

    event ProposalCompleted(
        uint indexed indexInProposalQueue,
        uint winningBallotItem
    );

    /********
    CONSTANTS
    ********/
    uint constant PROPOSAL_VOTE_TIME_SECONDS = 1;
    uint constant GRACE_PERIOD_SECONDS = 1;
    uint constant MIN_PROPOSAL_CREATION_DEPOSIT = 10 ether;
    uint constant LOSING_PROPOSAL_INDEX = 0;
    uint constant WINNING_PROPOSAL_INDEX = 1;

    struct Members { 
        mapping (address => bool) approved;
        mapping (address => address[]) tokenTributeAddresses;
        mapping (address => uint256[]) tokenTributeAmounts;
    }


    /******************
    PROPOSAL DEFINITION
    ******************/
    enum ProposalTypes {
        Membership,
        Project
    }

    enum ProposalPhase {
        Proposed,
        Voting,
        GracePeriod,
        Done
    }

    struct ProspectiveMember {
        address prospectiveMemberAddress; 
        uint256 ethTributeAmount; // eth tribute
        address[] tokenTributeAddresses; // array of token tributes
        uint256[] tokenTributeAmounts; // array of token tributes
    }

    struct ProspectiveProject {
        bytes32 ipfsHash; // information about proposal
        uint256 deposit; // deposit given
    }

    struct Proposal {
        // COMMON PROPOSAL ATTRIBUTES
        address proposer; // who proposed this
        ProposalTypes proposalType; // type
        uint256 votingSharesRequested; // num voting shares requested

        // PROJECT SPECIFIC ATTRIBUTES
        ProspectiveProject prospectiveProject;

        // MEMBER SPECIFIC ATTRIBUTES
        ProspectiveMember prospectiveMember;

        // BOOKKEEPING
        VotingLib.Ballot ballot; // proposal voting ballot
        ProposalPhase phase; // phase
        uint gracePeriodStartTime; // when did grace period start
    }

    struct ProposalQueue {
        Proposal[] proposals;
        uint256 currentProposalIndex;
    }

    /***************
    PUBLIC FUNCTIONS
    ***************/

    /*******************************
    SET CONTRACT REFERENCE FUNCTIONS
    *******************************/

    /**************
    CREATE PROPOSAL
    **************/

    // MEMBER PROPOSAL
    function createMemberProposal(
        ProposalQueue storage proposalQueue,
        address _propospectiveMemberAddress,
        uint256 _ethTributeAmount,
        address[] _tokenTributeAddresses, 
        uint256[] _tokenTributeAmounts,
        uint256 _votingSharesRequested,
        GuildBank _guildBank
    )
        public
    {
        // require tribute
        require((_ethTributeAmount > 0) || (_tokenTributeAddresses.length > 0), "TownHallLib::createMemberProposal - minimum tribute not met");

        // TODO DO WE NEED MIN DEPOSIT HERE?

        // set up proposal
        Proposal memory membershipProposal;

        // from inputs
        membershipProposal.votingSharesRequested = _votingSharesRequested;
        membershipProposal.prospectiveMember.prospectiveMemberAddress = _propospectiveMemberAddress;
        membershipProposal.prospectiveMember.tokenTributeAddresses = _tokenTributeAddresses;
        membershipProposal.prospectiveMember.tokenTributeAmounts = _tokenTributeAmounts;

        // attributes
        membershipProposal.proposer = msg.sender;
        membershipProposal.proposalType = ProposalTypes.Membership;
        membershipProposal.phase = ProposalPhase.Proposed;

        // eth tribute is in calling contract payable function
        membershipProposal.prospectiveMember.ethTributeAmount = _ethTributeAmount;
        address(_guildBank).call.value(msg.value);

        // collect token tribute
        for(uint8 i = 0; i < membershipProposal.prospectiveMember.tokenTributeAddresses.length; i++) {
            require(membershipProposal.prospectiveMember.tokenTributeAmounts[i] > 0, "TownHallLib::createMemberProposal - minimum token tribute no met"); // need non zero amounts
            ERC20 erc20 = ERC20(membershipProposal.prospectiveMember.tokenTributeAddresses[i]);

            // transfer tokens to this contract as tribute
            // approval must be granted prior to this step
            require(erc20.transferFrom(_propospectiveMemberAddress, _guildBank, _tokenTributeAmounts[i]), "TownHallLib::createMemberProposal - token transfer failure");
        }

        // push to end of proposal queue
        proposalQueue.proposals.push(membershipProposal);

        emit ProposalCreated(
            msg.sender,
            _votingSharesRequested,
            ProposalTypes.Membership,
            proposalQueue.proposals.length
        );


    }

    // PROJECT PROPOSAL
    function createProjectProposal(
        ProposalQueue storage proposalQueue,
        uint256 _ethDepositAmount,
        bytes32 _ipfsHash,
        uint256 _votingSharesRequested
    )
        public
    {
        // require min deposit
        require(_ethDepositAmount == MIN_PROPOSAL_CREATION_DEPOSIT, "TownHallLib::createProjectProposal - minimum ETH deposit no met");

        // set up proposal
        Proposal memory projectProposal;

        // from inputs
        projectProposal.prospectiveProject.ipfsHash = _ipfsHash;
        projectProposal.prospectiveProject.deposit = _ethDepositAmount;

        // attributes
        projectProposal.proposer = msg.sender;
        projectProposal.proposalType = ProposalTypes.Project;
        projectProposal.phase = ProposalPhase.Proposed;

        // push to end of proposal queue
        proposalQueue.proposals.push(projectProposal);

        emit ProposalCreated(msg.sender, _votingSharesRequested, ProposalTypes.Project, proposalQueue.proposals.length);
    }

    /***************
    VOTE ON PROPOSAL
    ***************/

    // TRANSITION STATE TO VOTING
    function startProposalVote(
        ProposalQueue storage proposalQueue,
        VotingShares votingShares
    ) 
        public 
    {
        // make sure previous proposal vote is completed
        if (proposalQueue.currentProposalIndex > 0) {
            // take care of initial case
            Proposal memory lastProposal = proposalQueue.proposals[proposalQueue.currentProposalIndex - 1];
            require(lastProposal.phase == ProposalPhase.Done, "TownHallLib::startProposalVote - previous proposal not done"); // past voting and grace period
        }

        Proposal storage currentProposal = proposalQueue.proposals[proposalQueue.currentProposalIndex];

        // create ballot
        VotingLib.Ballot memory ballot;
        currentProposal.ballot = ballot;
        currentProposal.ballot.initialize(2, PROPOSAL_VOTE_TIME_SECONDS, votingShares);

        // change phase
        currentProposal.phase = ProposalPhase.Voting;
        
        emit ProposalVotingStarted(proposalQueue.currentProposalIndex);
    }

    // VOTE
    function voteOnCurrentProposal(
        ProposalQueue storage proposalQueue,
        uint8 _toBallotItem
    ) 
        public 
    {
        Proposal storage currentProposal = proposalQueue.proposals[proposalQueue.currentProposalIndex];
        require(currentProposal.phase == ProposalPhase.Voting, "TownHallLib::voteOnCurrentProposal - curent proposal not in voting phase");

        currentProposal.ballot.vote(_toBallotItem);
    }

    /***********
    GRACE PERIOD
    ***********/

    function transitionProposalToGracePeriod(
        ProposalQueue storage proposalQueue
    )
        public 
    {
        Proposal storage currentProposal = proposalQueue.proposals[proposalQueue.currentProposalIndex];
        require(currentProposal.phase == ProposalPhase.Voting, "TownHallLib::transitionProposalToGracePeriod - curent proposal not in voting phase");

        // require vote time completed
        require(currentProposal.ballot.voteEnded());

        // transition state to grace period
        currentProposal.phase = ProposalPhase.GracePeriod;
        currentProposal.gracePeriodStartTime = now;

        emit ProposalGracePeriodStarted(proposalQueue.currentProposalIndex);
    }

    /*****
    FINISH
    *****/

    function finishProposal(
        ProposalQueue storage proposalQueue,
        Members storage members,
        GuildBank guildBank,
        VotingShares votingShares,
        LootToken lootToken
    ) 
        public 
    {
        Proposal storage currentProposal = proposalQueue.proposals[proposalQueue.currentProposalIndex];

        // require grace period elapsed
        require(currentProposal.phase == ProposalPhase.GracePeriod, "TownHallLib::finishProposal - curent proposal not in grace phase");
        require(now > currentProposal.gracePeriodStartTime + GRACE_PERIOD_SECONDS, "TownHallLib::finishProposal - grace phase not complete");

        // get winner from ballot
        uint winningBallotItem = currentProposal.ballot.getWinningProposal();

        if (winningBallotItem == WINNING_PROPOSAL_INDEX) {
            if (currentProposal.proposalType == ProposalTypes.Membership) {
                // add member here
                _acceptMemberProposal(members, guildBank, votingShares, lootToken, currentProposal);
            } else if (currentProposal.proposalType == ProposalTypes.Project) {
                // accept proposal
                _acceptProjectProposal(votingShares, lootToken, currentProposal);
            }
        } else if (winningBallotItem == LOSING_PROPOSAL_INDEX) {
            // proposal loses, burn eth
            address(0).transfer(currentProposal.prospectiveProject.deposit);
        }

        emit ProposalCompleted(proposalQueue.currentProposalIndex, winningBallotItem);

        // close out and move on to next proposal
        currentProposal.phase = ProposalPhase.Done;
        proposalQueue.currentProposalIndex++;
    }

    /***************
    GETTER FUNCTIONS
    ***************/

    // GET COMMON ATTRIBUTES
    function getCurrentProposalCommonDetails(
        ProposalQueue storage proposalQueue
    ) 
        public 
        view 
        returns (
            address,
            ProposalTypes,
            uint256,
            ProposalPhase,
            uint
        ) 
    {
        Proposal memory proposal = proposalQueue.proposals[proposalQueue.currentProposalIndex];
        return(
            proposal.proposer,
            proposal.proposalType,
            proposal.votingSharesRequested,
            proposal.phase,
            proposal.gracePeriodStartTime
        );
    }

    function getCurrentProposalIndex(ProposalQueue storage proposalQueue) public view returns (uint) {
        return proposalQueue.currentProposalIndex;
    }

    // GET PROJECT PROPOSAL SPECIFIC ATTRIBUTES
    function getCurrentProposalProjectDetails(
        ProposalQueue storage proposalQueue
    ) 
        public
        view 
        returns (bytes32, uint256) 
    {
        Proposal memory proposal = proposalQueue.proposals[proposalQueue.currentProposalIndex];
        return(proposal.prospectiveProject.ipfsHash, proposal.prospectiveProject.deposit);
    }

    // GET MEMBER PROPOSAL SPECIFIC ATTRIBUTES
    function getCurrentProposalMemberDetails(
        ProposalQueue storage proposalQueue
    ) 
        public 
        view 
        returns (
            address, 
            uint256, 
            address[], 
            uint256[]
        ) 
    {
        Proposal memory proposal = proposalQueue.proposals[proposalQueue.currentProposalIndex];
        return(
            proposal.prospectiveMember.prospectiveMemberAddress,
            proposal.prospectiveMember.ethTributeAmount,
            proposal.prospectiveMember.tokenTributeAddresses,
            proposal.prospectiveMember.tokenTributeAmounts
        );
    }

    function getCurrentProposalBallot(
        ProposalQueue storage proposalQueue
    )
        public 
        view 
        returns (
            uint,
            uint,
            uint
        ) 
    {
        Proposal storage proposal = proposalQueue.proposals[proposalQueue.currentProposalIndex];
        return (
            proposal.ballot.votingEndDate,
            proposal.ballot.minVotesRequired,
            proposal.ballot.getLeadingProposal()
        );
    }

    function getMember(Members storage members, address memberAddress) public view returns (bool) {
        return members.approved[memberAddress];
    }

    /*****************
    INTERNAL FUNCTIONS
    *****************/

    // TRANSFER TRIBUTES TO GUILD BANK
    function _collectTributes(
        GuildBank guildBank,
        uint256 _ethTributeAmount,
        address[] _tokenTributeAddresses,
        uint256[] _tokenTributeAmounts
    ) 
        internal
    {
        // collect eth tribute
        if (_ethTributeAmount > 0) {
            address(guildBank).transfer(_ethTributeAmount);
        }

        // collect token tribute
        for (uint8 i = 0; i < _tokenTributeAddresses.length; i++) {
            ERC20 erc20 = ERC20(_tokenTributeAddresses[i]);
            require(erc20.approve(address(guildBank), _tokenTributeAmounts[i]), "TownHallLib::_collectTributes - could not collect token tribute");
            guildBank.offerTokens(erc20, _tokenTributeAmounts[i]);
        }
    }

    // DILUTE GUILD AND GRANT VOTING SHARES (MINT LOOT TOKENS)
    function _grantVotingShares(
        VotingShares votingShares,
        LootToken lootToken,
        address _to,
        uint256 _numVotingShares
    ) 
        internal 
    {
        // dilute and grant 
        votingShares.mint(msg.sender, _to, _numVotingShares);

        // mint loot tokens 1:1 and keep them in moloch contract for exit
        lootToken.mint(msg.sender, address(this), _numVotingShares);
    } 

    // ACCEPT MEMBER
    function _acceptMemberProposal(
        Members storage members,
        GuildBank guildBank,
        VotingShares votingShares,
        LootToken lootToken,
        Proposal memberProposal
    ) 
        internal 
    {
        // collect tributes into bank
        _collectTributes(
            guildBank,
            memberProposal.prospectiveMember.ethTributeAmount,
            memberProposal.prospectiveMember.tokenTributeAddresses,
            memberProposal.prospectiveMember.tokenTributeAmounts
        );

        // add to moloch members
        address newMemberAddress = memberProposal.prospectiveMember.prospectiveMemberAddress;
        members.approved[newMemberAddress] = true;
        members.tokenTributeAddresses[newMemberAddress] = memberProposal.prospectiveMember.tokenTributeAddresses;
        members.tokenTributeAmounts[newMemberAddress] = memberProposal.prospectiveMember.tokenTributeAmounts;

        // grant shares to new member
        _grantVotingShares(
            votingShares,
            lootToken,
            newMemberAddress,
            memberProposal.votingSharesRequested
        );
    }

    // ACCEPT PROJECT
    function _acceptProjectProposal(
        VotingShares votingShares,
        LootToken lootToken,
        Proposal projectProposal
    ) 
        internal 
    {
        // grant shares to proposer
        _grantVotingShares(
            votingShares,
            lootToken,
            projectProposal.proposer,
            projectProposal.votingSharesRequested
        );

        // transfer deposit back to proposer
        projectProposal.proposer.transfer(projectProposal.prospectiveProject.deposit);
    }
}