pragma solidity ^0.4.17;

import './StandardToken.sol';

/// @title xChainge Token
contract xChaingeToken is StandardToken {

    /*
     *  Terminology:
     *  1 token unit = Xei
     *  1 token = XCT = Xei * multiplier
     *  multiplier set from token's number of decimals (i.e. 10 ** decimals)
     */

    /*
     *  Token metadata
     */
    string constant public name = "xChainge Token";
    string constant public symbol = "XCT";
    uint8 constant public decimals = 18;
    uint constant multiplier = 10 ** uint(decimals);

    event Deployed(uint indexed _totalSupply);
    event Burnt(address indexed _receiver, uint indexed _num, uint indexed _totalSupply);

    /*
     *  Public functions
     */
    /// @dev Contract constructor function sets dutch auction contract address
    /// and assigns all tokens to dutch auction.
    /// @param auctionAddress Address of dutch auction contract.
    /// @param walletAddress Address of wallet.
    /// @param auctionSupply Number of initially provided token units (Xei) for crowdsale rewards.
    /// @param walletSupply Number of initially provided token units (Xei) for team, advisors and bounty.
    function xChaingeToken(address auctionAddress, address walletAddress, uint auctionSupply, uint walletSupply) public
    {
        // Auction address should not be null.
        require(auctionAddress != 0x0);
        require(walletAddress != 0x0);

        // Supply is in Xei
        require(auctionSupply > multiplier);
        require(walletSupply > multiplier);

        // Total supply of Xei at deployment
        totalSupply = auctionSupply + walletSupply;

        balances[auctionAddress] = auctionSupply;
        balances[walletAddress] = walletSupply;

        Transfer(0x0, auctionAddress, auctionSupply);
        Transfer(0x0, walletAddress, walletSupply);

        Deployed(totalSupply);

        assert(totalSupply == balances[auctionAddress] + balances[walletAddress]);
    }

    /// @notice Allows `msg.sender` to simply destroy `num` token units (Xei). This means the total
    /// token supply will decrease.
    /// @dev Allows to destroy token units (Xei).
    /// @param num Number of token units (Xei) to burn.
    function burn(uint num) public {
        require(num > 0);
        require(balances[msg.sender] >= num);
        require(totalSupply >= num);

        uint preBalance = balances[msg.sender];

        balances[msg.sender] -= num;
        totalSupply -= num;
        Burnt(msg.sender, num, totalSupply);
        Transfer(msg.sender, 0x0, num);

        assert(balances[msg.sender] == preBalance - num);
    }
}