// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BeefyGems} from "./BeefyGems.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title Beefy Gems Factory
/// @author Beefy, weso
/// @dev Beefy Gems Season Program Factory
contract BeefyGemsFactory is Ownable {
    using Clones for address;

    BeefyGems public instance;
    address public treasury;

    struct Season {
        uint256 seasonNum;
        address gems;
        uint256 amountOfS;
    }

    Season[] private seasons;

    event NewSeason(uint256 indexed seasonNum, uint256 amountOfGems, address gems);
    event OpenSeason(uint256 indexed seasonNum, uint256 amountOfS);
    event Redeemed(address indexed who, uint256 indexed seasonNum, uint256 amount, uint256 amountOfS);
    event TopUpSeason(uint256 indexed seasonNum, uint256 amountOfS);

    error RedemptionNotOpen();
    error NotEnoughS();
    error SeasonAlreadyOpen();
    error NotYourGems();
    error NoMoreGems();
    
    constructor(
        address _treasury
    ) Ownable(msg.sender) {
        instance = new BeefyGems();
        treasury = _treasury;
    }

    /// @notice Create a new season
    /// @param _amountOfGems Amount of gems to be minted
    function createSeason(uint256 _amountOfGems) external onlyOwner {
        uint256 seasonNum = seasons.length + 1;

        address gems = address(instance).clone();

        string memory name = string.concat("Beefy Gems Season ", Strings.toString(seasonNum));
        string memory symbol = string.concat("beGEMS", Strings.toString(seasonNum));

        BeefyGems(gems).initialize(
            name,
            symbol,
            treasury,
            _amountOfGems,
            seasonNum
        );

        Season memory season = Season({
            seasonNum: seasonNum,
            gems: gems,
            amountOfS: 0
        });

        seasons.push(season);

        emit NewSeason(seasonNum, _amountOfGems, gems);
    }

    /// @notice Open a season for redemption
    /// @param seasonNum Season number
    function openSeasonRedemption(uint256 seasonNum) external payable onlyOwner {
        Season storage season = seasons[seasonNum - 1];
        if (season.amountOfS > 0) revert SeasonAlreadyOpen();
        if (BeefyGems(season.gems).totalSupply() == 0) revert NoMoreGems();
        if (msg.value == 0) revert NotEnoughS();
        season.amountOfS = msg.value;

        emit OpenSeason(seasonNum, season.amountOfS);
    }

    /// @notice Top up a season with more S
    /// @param seasonNum Season number
    function topUpSeason(uint256 seasonNum) external payable onlyOwner {
        Season storage season = seasons[seasonNum - 1];
        if (season.amountOfS == 0) revert RedemptionNotOpen();
        season.amountOfS += msg.value;

        emit TopUpSeason(seasonNum, season.amountOfS);
    }
    
    /// @notice Get the number of seasons
    /// @return Number of seasons
    function numSeasons() external view returns (uint256) {
        return seasons.length;
    }

    /// @notice Get a season by season number
    /// @param _seasonNum Season number
    /// @return Season memory
    function getSeason(uint256 _seasonNum) external view returns (Season memory) {
        return seasons[_seasonNum - 1];
    }

    /// @notice Redeem gems for S
    /// @param seasonNum Season number
    /// @param _amount Amount of gems to redeem
    function redeem(uint256 seasonNum, uint256 _amount, address _who) external payable {
        Season storage season = seasons[seasonNum - 1];
        if (msg.sender != _who && msg.sender != season.gems) revert NotYourGems();
        if (BeefyGems(season.gems).totalSupply() == 0) revert RedemptionNotOpen();
        
        uint256 seasonAmountOfS = season.amountOfS;
        if (seasonAmountOfS == 0) revert RedemptionNotOpen();

        uint256 totalSupply = BeefyGems(season.gems).totalSupply();

        uint256 r = (seasonAmountOfS * _amount) / totalSupply;
        
        BeefyGems(season.gems).burn(_amount, _who);

        if (r > seasonAmountOfS) r = seasonAmountOfS;
        season.amountOfS -= r;

        (bool success, ) = _who.call{value: r}("");
        if (!success) revert NotEnoughS();

        emit Redeemed(_who, seasonNum, _amount, r);
    }

    /// @notice Get the price for a full share
    /// @param seasonNum Season number
    /// @return Price for a full share  
    function getPriceForFullShare(uint256 seasonNum) external view returns (uint256) {
        Season storage season = seasons[seasonNum - 1];
        uint256 totalSupply = BeefyGems(season.gems).totalSupply();
        if (totalSupply == 0) return 0;
        return season.amountOfS * 1e18 / totalSupply;
    }

    receive() external payable onlyOwner {}
}