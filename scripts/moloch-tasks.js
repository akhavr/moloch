const BN = require('bn.js')
const deploymentParams = require('../deployment-params')

const {
  getDeployedMoloch,
  getFirstAccount,
  getApprovedToken,
  hasEnoughTokens,
  hasEnoughAllowance,
  giveAllowance
} = require('./utils')

task('moloch-deploy', 'Deploys a new instance of the Moloch DAO')
  .setAction(async () => {
    if (deploymentParams.SUMMONER === '' || deploymentParams.TOKEN === '') {
      console.error('Please set the deployment parameters in deployment-params.js')
      return
    }

    // Make sure everything is compiled
      await run('compile')

    console.log('Deploying a new DAO to the network ' + buidlerArguments.network)
    console.log(
      'Deployment parameters:\n',
      '  summoner:', deploymentParams.SUMMONER, '\n',
      '  token:', deploymentParams.TOKEN, '\n',
      '  periodSeconds:', deploymentParams.PERIOD_DURATION_IN_SECONDS, '\n',
      '  votingPeriods:', deploymentParams.VOTING_DURATON_IN_PERIODS, '\n',
      '  gracePeriods:', deploymentParams.GRACE_DURATON_IN_PERIODS, '\n',
	'  proposalDeposit:', web3.utils.fromWei(deploymentParams.PROPOSAL_DEPOSIT, 'ether'), '\n',
      '  dilutionBound:', deploymentParams.DILUTION_BOUND, '\n',
	'  processingReward:', web3.utils.fromWei(deploymentParams.PROCESSING_REWARD, 'ether'), '\n'
    )

    const Confirm = require('prompt-confirm')
    const prompt = new Confirm('Please confirm that the deployment parameters are correct')
    const confirmation = await prompt.run()

    if (!confirmation) {
      return
    }

    const Moloch = artifacts.require('Moloch')

    console.log("Deploying...")
    const moloch = await Moloch.new(
      deploymentParams.SUMMONER,
      [deploymentParams.TOKEN],
      deploymentParams.PERIOD_DURATION_IN_SECONDS,
      deploymentParams.VOTING_DURATON_IN_PERIODS,
      deploymentParams.GRACE_DURATON_IN_PERIODS,
      deploymentParams.PROPOSAL_DEPOSIT,
      deploymentParams.DILUTION_BOUND,
      deploymentParams.PROCESSING_REWARD
    )

    console.log("")
    console.log('Moloch DAO deployed. Address:', moloch.address)
    console.log("Set this address in buidler.config.js's networks section to use the other tasks")
  })

task('moloch-submit-proposal', 'Submits a proposal')
    .addParam('applicant', 'The address of the applicant')
    .addParam('shares', 'The number of shares requested')
    .addParam('loot', 'The number of loot requested')
    .addParam('tribute', "The number of token's wei offered as tribute")
    .addParam('tributeToken', "The token offered as tribute")
    .addParam('payment', 'The payment requested')
    .addParam('paymentToken', 'The payment token requested')
    .addParam('details', "The proposal's details")
    .setAction(async ({ applicant, shares, loot, tribute, tributeToken, payment, paymentToken, details }) => {
    // Make sure everything is compiled
    await run('compile')

    const moloch = await getDeployedMoloch()
    if (moloch === undefined) {
      return
    }

    const token = await getApprovedToken()
    if (token === undefined) {
      return
    }

    const proposalDeposit = await moloch.proposalDeposit()
    const sender = await getFirstAccount()

    if (!await hasEnoughTokens(token, sender, proposalDeposit)) {
      console.error("You don't have enough tokens to pay the deposit")
      return
    }

    if (!await hasEnoughAllowance(token, sender, moloch, proposalDeposit)) {
      await giveAllowance(token, sender, moloch, proposalDeposit)
    }

    if (new BN(tribute).gt(new BN(0))) {
      if (!await hasEnoughTokens(token, applicant, tribute)) {
        console.error("The applicant doesn't have enough tokens to pay the tribute")
        return
      }

	if (!await hasEnoughAllowance(token, applicant, moloch, tribute)) {
            console.error('The applicant must give allowance to the DAO before being proposed')
            return
	}
    }

	const { receipt } = await moloch.submitProposal(applicant,
							shares,
							loot,
							tribute,
							tributeToken,
							payment,
							paymentToken,
							details)
    const proposalIndex = receipt.logs[0].args.proposalId

    console.log('Submitted proposal number', proposalIndex.toString())
    })

task('moloch-submit-whitelist', 'Submits a token whitelist proposal')
    .addParam('token', 'The token to be whitelisted')
    .addParam('details', "The proposal's details")
    .setAction(async ({token, details}) => {
	// Make sure everything is compiled
	await run('compile')

	const moloch = await getDeployedMoloch()
	if (moloch === undefined) {
	    return
	}

	const {receipt} = await moloch.submitWhitelistProposal(token, details)
	const proposalId = receipt.logs[0].args.proposalId
	console.log('Submitted proposal number', proposalId.toString())
    })

task('moloch-submit-kick', 'Submits a member kick proposal')
    .addParam('member', 'The member to be kicked')
    .addParam('details', "The proposal's details")
    .setAction(async ({member, details}) => {
	// Make sure everything is compiled
	await run('compile')

	const moloch = await getDeployedMoloch()
	if (moloch === undefined) {
	    return
	}

	const {receipt} = await moloch.submitGuildKickProposal(member, details)
	const proposalId = receipt.logs[0].args.proposalId
	console.log('Submitted proposal number', proposalId.toString())
    })

task('moloch-list-proposals', 'Lists proposals')
    .setAction(async () => {
	// Make sure everything is compiled
	await run('compile')

	const moloch = await getDeployedMoloch()
	if (moloch === undefined) {
	    return
	}

	const count = await moloch.proposalCount();
	console.log('Total # of proposals', count.toString())

	var i;
	console.log('Actors\tShares\tLoot\tTribute\tPayment\tPeriod\tVotes\tDetails')
	for(i=0; i < count; i++) {
	    const proposal = await moloch.proposals(i);
	    console.log(`${i}.`, 
			proposal['applicant'].toString(),
			proposal['sharesRequested'].toString(),
			proposal['lootRequested'].toString(),
			`${web3.utils.fromWei(proposal['tributeOffered'], 'ether')}/${proposal['tributeToken'].toString()}`,
			`${proposal['paymentRequested'].toString()}/${proposal['paymentToken'].toString()}`,
			proposal['startingPeriod'].toString(),
			`${proposal['yesVotes'].toString()}/${proposal['noVotes'].toString()}`,
			proposal['details'].toString())
	    console.log('  ', proposal['proposer'].toString())
	    console.log('  ', proposal['sponsor'].toString())
	}
    })

task('moloch-list-members', 'Lists members')
    .setAction(async() => {
	await run('compile')

	const moloch = await getDeployedMoloch()
	if( moloch === undefined ) {
	    return
	}

	var proposals = [];

	await moloch.getPastEvents('ProcessProposal', {fromBlock: 10411729, toBlock: 'latest'}).then(
	    function(events){ events.forEach(ev => {
		const didPass = ev['returnValues']['didPass']
		const proposalIndex = ev['returnValues']['proposalIndex']
		const proposalId = ev['returnValues']['proposalId']
		if(didPass) {
		    proposals.push(proposalIndex)
		}
	    }
					    ) } );
	for(var i=0; i<proposals.length; ++i) {
	    const proposal = await moloch.proposals(i);
	    console.log(`${i}.`,
			proposal['applicant'].toString(),
		       )
	    const member = await moloch.members(proposal['applicant']);
	    const balance = await moloch.getUserTokenBalance(proposal['applicant'], proposal['tributeToken']);
	    console.log(member['delegateKey'], member['shares'].toString(), member['loot'].toString(),
			member['exists'].toString(), member['jailed'].toString(),
			`${web3.utils.fromWei(balance, 'ether')}`);
	}
    })

task('moloch-sponsor-proposal', 'Sponsor proposal')
    .addParam('proposal', 'The proposal id', undefined, types.int)
    .setAction(async({proposal}) => {
	// Make sure everything is compiled
	await run('compile')

	const moloch = await getDeployedMoloch()
	if(moloch === undefined) {
	    return
	}

	const deposit_token = await getApprovedToken()
	if (deposit_token === undefined) {
	    return
	}

	const proposal_deposit = await moloch.proposalDeposit()
	const sponsor = await getFirstAccount()

	console.log('Sponsoring proposal', proposal)
	
	if (!await hasEnoughAllowance(deposit_token, sponsor, moloch, proposal_deposit)) {
            console.error('The sponsor must give allowance to the DAO before sponsoring')
	    const allowance = await deposit_token.allowance(sponsor, moloch.address)

	    console.error('Allowance now:', web3.utils.fromWei(allowance, 'ether'))
	    console.error('Allowance required:', web3.utils.fromWei(proposal_deposit, 'ether'))
            return
	}

	const {receipt} = await moloch.sponsorProposal(proposal)
	for(var i=0; i < receipt.logs.length; ++i) {
	    event = receipt.logs[i].args;
	    console.log('Delegate key:', event.delegateKey);
	    console.log('Member:', event.memberAddress);
	    console.log('Proposal id:', event.proposalId.toString());
	    console.log('Proposal index in the queue:', event.proposalIndex.toString());
	    console.log('Starting period:', event.startingPeriod.toString());
	}

	console.log('Done')
    })

task('moloch-cancel-proposal', 'Cancel proposal')
    .addParam('proposal', 'The proposal id', undefined, types.int)
    .setAction(async({proposal}) => {
	// Make sure everything is compiled
	await run('compile')

	const moloch = await getDeployedMoloch()
	if(moloch === undefined) {
	    return
	}

	await moloch.cancelProposal(proposal)
	console.log(`Proposal ${proposal} canceled`)
    })

task('moloch-submit-vote', 'Submits a vote')
  .addParam('proposal', 'The proposal number', undefined, types.int)
  .addParam('vote', 'The vote (yes/no)')
  .setAction(async ({ proposal, vote }) => {
    // Make sure everything is compiled
    await run('compile')

    const moloch = await getDeployedMoloch()
    if (moloch === undefined) {
      return
    }

    if (vote.toLowerCase() !== 'yes' && vote.toLowerCase() !== 'no') {
      console.error('Invalid vote. It must be "yes" or "no".')
      return
    }

    const voteNumber = vote.toLowerCase() === 'yes' ? 1 : 2

    await moloch.submitVote(proposal, voteNumber)
    console.log('Vote submitted')
  })

task('moloch-process-proposal', 'Processes a proposal')
  .addParam('proposal', 'The proposal number', undefined, types.int)
  .setAction(async ({ proposal }) => {
    // Make sure everything is compiled
    await run('compile')

    const moloch = await getDeployedMoloch()
    if (moloch === undefined) {
      return
    }

    await moloch.processProposal(proposal)
    console.log('Proposal processed')
  })

task('moloch-process-whitelist', 'Processes a whitelist proposal')
    .addParam('proposal', 'The proposal number', undefined, types.int)
    .setAction(async ({ proposal }) => {
	// Make sure everything is compiled
	await run('compile')

	const moloch = await getDeployedMoloch()
	if (moloch === undefined) {
	    return
	}

	await moloch.processWhitelistProposal(proposal)
	console.log('Proposal processed')
    })


task('moloch-process-kick', 'Processes a kick proposal')
    .addParam('proposal', 'The proposal number', undefined, types.int)
    .setAction(async ({ proposal }) => {
	// Make sure everything is compiled
	await run('compile')

	const moloch = await getDeployedMoloch()
	if (moloch === undefined) {
	    return
	}

	await moloch.processGuildKickProposal(proposal)
	console.log('Proposal processed')
    })

task('moloch-ragequit', 'Ragequits, burning some shares and loot and getting tokens back')
  .addParam('shares', 'The amount of shares to burn')
  .addParam('loot', 'The amount of loot to burn')
    .setAction(async ({ shares, loot }) => {
    // Make sure everything is compiled
    await run('compile')

    const moloch = await getDeployedMoloch()
    if (moloch === undefined) {
      return
    }

	await moloch.ragequit(shares, loot)
	console.log(`Burn ${shares} shares and ${loot} loot`)
  })

task('moloch-ragekick', 'Ragekick a jailed member')
  .addParam('member', 'Member to kick')
    .setAction(async ({ member }) => {
	// Make sure everything is compiled
	await run('compile')

	const moloch = await getDeployedMoloch()
	if (moloch === undefined) {
	    return
	}

	await moloch.ragekick(member)
	console.log(`Member ${member} ragekicked`)
  })

task('moloch-update-delegate', 'Updates your delegate')
  .addParam('delegate', "The new delegate's address")
  .setAction(async ({ delegate }) => {
    // Make sure everything is compiled
    await run('compile')

    const moloch = await getDeployedMoloch()
    if (moloch === undefined) {
      return
    }

    await moloch.updateDelegateKey(delegate)
    console.log(`Delegate updated`)
  })

task('moloch-withdraw', 'Withdraws specified amount of tokens')
    .addParam('token', 'Token to withdraw')
    .addParam('amount', 'Amount to withdraw')
    .setAction(async({token, amount}) => {
	await run('compile')

	const moloch = await getDeployedMoloch()
	if(moloch === undefined) {
	    return
	}
	await moloch.withdrawBalance(token, web3.utils.toWei(amount, 'ether'))
	console.log(`${amount} of ${token} withdrawn`)
    })

task('moloch-collect', 'Collects specified tokens from applicant')
    .addParam('token', 'Token to withdraw')
    .setAction(async({token}) => {
	// Make sure everything is compiled
	await run('compile')

	const moloch = await getDeployedMoloch()
	if (moloch === undefined) {
	    return
	}

	await moloch.collectTokens(token)
	console.log(`Delegate updated`)
    })

