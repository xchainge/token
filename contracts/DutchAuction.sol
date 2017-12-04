pragma solidity ^0.4.17;

import './xChaingeToken.sol';

/// @title Dutch auction contract - distribution of a fixed number of tokens using an auction.
/// The contract code is inspired by the Gnosis and Raiden auction contract. 
/// Auction ends if a fixed number of tokens was sold.
contract DutchAuction {
    /*
     * Auction for the XCT Token.
     *
     * Terminology:
     * 1 token unit = Xei
     * 1 token = XCT = Xei * multiplier
     * multiplier set from token's number of decimals (i.e. 10 ** decimals)
     */

    // Wait 7 days after the end of the auction, before anyone can claim tokens
    uint constant public tokenClaimWaitingPeriod = 7 days;

    /*
     * Storage
     */

    xChaingeToken public token;
    address public ownerAddress;
    address public walletAddress;

    // Price decay function parameters to be changed depending on the desired outcome

    // Starting price in WEI; e.g. 2 * 10 ** 18
    uint public priceStart;

    // Divisor constant; e.g. 524880000
    uint public priceConstant;

    // Divisor exponent; e.g. 3
    uint32 public priceExponent;

    // For calculating elapsed time for price
    uint public startTime;
    uint public endTime;
    uint public startBlock;

    // Keep track of all ETH received in the bids
    uint public receivedWei;

    // Keep track of cumulative ETH funds for which the tokens have been claimed
    uint public fundsClaimed;

    uint public tokenMultiplier;

    uint public softCap;
    uint public minPrice;

    // Total number of Xei (XCT * multiplier) that will be auctioned
    uint public numTokensAuctioned;

    // Wei per XCT (Xei * multiplier)
    uint public finalPrice;

    // Bidder address => bid value
    mapping (address => uint) public bids;

    Stages public stage;

    /*
     * Enums
     */
    enum Stages {
        AuctionDeployed,
        AuctionSetUp,
        AuctionStarted,
        AuctionEnded,
        AuctionCanceled,
        TokensDistributed
    }

    /*
     * Modifiers
     */
    modifier atStage(Stages _stage) {
        require(stage == _stage);
        _;
    }

    modifier isOwner() {
        require(msg.sender == ownerAddress);
        _;
    }

    /*
     * Events
     */

    event Deployed(uint indexed _priceStart, uint indexed _priceConstant, uint32 indexed _priceExponent);
    event Setup();
    event AuctionStarted(uint indexed _startTime, uint indexed _blockNumber);
    event BidSubmission(address indexed _sender, uint _amount, uint _missingFunds);
    event ClaimedTokens(address indexed _recipient, uint _sentAmount);
    event AuctionEnded(uint _finalPrice);
    event TokensDistributed();
    event AuctionCanceled();

    /*
     * Public functions
     */

    /// @dev Contract constructor function sets the starting price, divisor constant and
    /// divisor exponent for calculating the Dutch Auction price.
    /// @param _priceStart High price in WEI at which the auction starts.
    /// @param _priceConstant Auction price divisor constant.
    /// @param _priceExponent Auction price divisor exponent.
    function DutchAuction(
        address _walletAddress,
        uint _priceStart, 
        uint _priceConstant, 
        uint32 _priceExponent) 
        public
    {
        require(_walletAddress != 0x0);
        walletAddress = _walletAddress;

        ownerAddress = msg.sender;
        stage = Stages.AuctionDeployed;
        changeSettings(_priceStart, _priceConstant, _priceExponent);
        Deployed(_priceStart, _priceConstant, _priceExponent);
    }

    /// @dev Fallback function for the contract, which calls bid() if the auction has started.
    function () public payable atStage(Stages.AuctionStarted) {
        bid();
    }

    /// @notice Set `_tokenAddress` as the token address to be used in the auction.
    /// @dev Setup function sets external contracts addresses.
    /// @param _tokenAddress Token address.
    function setup(address _tokenAddress, uint _softCap, uint _minPrice) public isOwner atStage(Stages.AuctionDeployed) {
        require(_tokenAddress != 0x0);
        token = xChaingeToken(_tokenAddress);

        // Get number of Xei (XCT * multiplier) to be auctioned from token auction balance
        numTokensAuctioned = token.balanceOf(address(this));

        // Set the number of the token multiplier for its decimals
        tokenMultiplier = 10 ** uint(token.decimals());

        require(softCap > 0);
        softCap = _softCap;

        require(minPrice > 0);
        minPrice = _minPrice;

        stage = Stages.AuctionSetUp;
        Setup();
    }

    /// @notice Set `_priceStart`, `_priceConstant` and `_priceXxponent` as
    /// the new starting price, price divisor constant and price divisor exponent.
    /// @dev Changes auction price function parameters before auction is started.
    /// @param _priceStart Updated start price.
    /// @param _priceConstant Updated price divisor constant.
    /// @param _priceExponent Updated price divisor exponent.
    function changeSettings(uint _priceStart, uint _priceConstant, uint32 _priceExponent) internal
    {
        require(stage == Stages.AuctionDeployed || stage == Stages.AuctionSetUp);
        require(_priceStart > 0);
        require(_priceConstant > 0);

        priceStart = _priceStart;
        priceConstant = _priceConstant;
        priceExponent = _priceExponent;
    }

    /// @notice Start the auction.
    /// @dev Starts auction and sets startTime.
    function startAuction() public isOwner atStage(Stages.AuctionSetUp) {
        stage = Stages.AuctionStarted;
        startTime = now;
        startBlock = block.number;
        AuctionStarted(startTime, startBlock);
    }

    /// @notice Finalize the auction - sets the final XCT token price and changes the auction
    /// stage after no bids are allowed anymore.
    /// @dev Finalize auction and set the final XCT token price.
    function finalizeAuction() public isOwner atStage(Stages.AuctionStarted)
    {
        endTime = now;

        if (receivedWei < softCap){
            stage = Stages.AuctionCanceled;
            AuctionCanceled();
            return;
        }

        // Send ETH to wallet
        walletAddress.transfer(receivedWei);

        uint missingFunds = missingFundsToEndAuction();
        if (missingFunds > 0){
            uint soldTokens = tokenMultiplier * receivedWei / minPrice;
            uint burnTokens = numTokensAuctioned - soldTokens;
            token.burn(burnTokens);
            numTokensAuctioned -= burnTokens;
        }

        // Calculate the final price = WEI / XCT = WEI / (Xei / multiplier)
        // Reminder: numTokensAuctioned is the number of Xei (XCT * multiplier) that are auctioned
        finalPrice = tokenMultiplier * receivedWei / numTokensAuctioned;

        stage = Stages.AuctionEnded;
        AuctionEnded(finalPrice);

        assert(finalPrice > 0);
    }

    /// --------------------------------- Auction Functions ------------------


    /// @notice Send `msg.value` WEI to the auction from the `msg.sender` account.
    /// @dev Allows to send a bid to the auction.
    function bid() public payable atStage(Stages.AuctionStarted)
    {
        require(msg.value > 0);
        assert(bids[msg.sender] + msg.value >= msg.value);

        // Missing funds without the current bid value
        uint missingFunds = missingFundsToEndAuction();

        // We require bid values to be less than the funds missing to end the auction
        // at the current price.
        require(msg.value <= missingFunds);

        bids[msg.sender] += msg.value;
        receivedWei += msg.value;

        BidSubmission(msg.sender, msg.value, missingFunds);

        assert(receivedWei >= msg.value);
    }

    /// @notice Claim auction tokens for `msg.sender` after the auction has ended.
    /// @dev Claims tokens for `msg.sender` after auction. To be used if tokens can
    /// be claimed by beneficiaries, individually.
    function claimTokens() public atStage(Stages.AuctionEnded) returns (bool) {
        return proxyClaimTokens(msg.sender);
    }

    /// @notice Claim auction tokens for `receiverAddress` after the auction has ended.
    /// @dev Claims tokens for `receiverAddress` after auction has ended.
    /// @param receiverAddress Tokens will be assigned to this address if eligible.
    function proxyClaimTokens(address receiverAddress) public atStage(Stages.AuctionEnded) returns (bool)
    {
        // Waiting period after the end of the auction, before anyone can claim tokens
        // Ensures enough time to check if auction was finalized correctly
        // before users start transacting tokens
        require(now > endTime + tokenClaimWaitingPeriod);
        require(receiverAddress != 0x0);

        if (bids[receiverAddress] == 0) {
            return false;
        }

        // Number of Xei = bid wei / Xei = bid wei / (wei per XCT * multiplier)
        uint num = (tokenMultiplier * bids[receiverAddress]) / finalPrice;

        // Due to finalPrice floor rounding, the number of assigned tokens may be higher
        // than expected. Therefore, the number of remaining unassigned auction tokens
        // may be smaller than the number of tokens needed for the last claimTokens call
        uint auctionTokensBalance = token.balanceOf(address(this));
        if (num > auctionTokensBalance) {
            num = auctionTokensBalance;
        }

        // Update the total amount of funds for which tokens have been claimed
        fundsClaimed += bids[receiverAddress];

        // Set receiver bid to 0 before assigning tokens
        bids[receiverAddress] = 0;

        require(token.transfer(receiverAddress, num));

        ClaimedTokens(receiverAddress, num);

        // After the last tokens are claimed, we change the auction stage
        // Due to the above logic, rounding errors will not be an issue
        if (fundsClaimed == receivedWei) {
            stage = Stages.TokensDistributed;
            TokensDistributed();
        }

        assert(token.balanceOf(receiverAddress) >= num);
        assert(bids[receiverAddress] == 0);
        return true;
    }

    /// @notice Withdraw ETH for `msg.sender` after the auction has canceled.
    function withdraw() public atStage(Stages.AuctionCanceled) returns (bool) {
        return proxyWithdraw(msg.sender);
    }

    /// @notice Withdraw ETH for `receiverAddress` after the auction has canceled.
    /// @param receiverAddress ETH will be assigned to this address if eligible.
    function proxyWithdraw(address receiverAddress) public atStage(Stages.AuctionCanceled) returns (bool) {
        require(receiverAddress != 0x0);
        
        if (bids[receiverAddress] == 0) {
            return false;
        }

        uint amount = bids[receiverAddress];
        bids[receiverAddress] = 0;
        
        receiverAddress.transfer(amount);

        assert(bids[receiverAddress] == 0);
        return true;
    }

    /// @notice Get the XCT price in WEI during the auction, at the time of
    /// calling this function. Returns `0` if auction has ended.
    /// Returns `priceStart` before auction has started.
    /// @dev Calculates the current XCT token price in WEI.
    /// @return Returns WEI per XCT (Xei * multiplier).
    function price() public constant returns (uint) {
        if (stage == Stages.AuctionEnded ||
            stage == Stages.AuctionCanceled ||
            stage == Stages.TokensDistributed) {
            return 0;
        }
        return calcTokenPrice();
    }

    /// @notice Get the missing funds needed to end the auction,
    /// calculated at the current XCT price in WEI.
    /// @dev The missing funds amount necessary to end the auction at the current XCT price in WEI.
    /// @return Returns the missing funds amount in WEI.
    function missingFundsToEndAuction() constant public returns (uint) {

        // numTokensAuctioned = total number of Xei (XCT * multiplier) that is auctioned
        uint requiredWeiAtPrice = numTokensAuctioned * price() / tokenMultiplier;
        if (requiredWeiAtPrice <= receivedWei) {
            return 0;
        }

        // assert(requiredWeiAtPrice - receivedWei > 0);
        return requiredWeiAtPrice - receivedWei;
    }

    /*
     *  Private functions
     */

    /// @dev Calculates the token price (WEI / XCT) at the current timestamp
    /// during the auction; elapsed time = 0 before auction starts.
    /// Based on the provided parameters, the price does not change in the first
    /// `priceConstant^(1/priceExponent)` seconds due to rounding.
    /// Rounding in `decayRate` also produces values that increase instead of decrease
    /// in the beginning; these spikes decrease over time and are noticeable
    /// only in first hours. This should be calculated before usage.
    /// @return Returns the token price - Wei per XCT.
    function calcTokenPrice() constant private returns (uint) {
        uint elapsed;
        if (stage == Stages.AuctionStarted) {
            elapsed = now - startTime;
        }

        uint decayRate = elapsed ** priceExponent / priceConstant;
        uint currentPrice = priceStart * (1 + elapsed) / (1 + elapsed + decayRate);
        return minPrice > currentPrice ? minPrice : currentPrice;
    }
}