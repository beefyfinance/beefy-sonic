// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {BeefyGems} from "./BeefyGems.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract BeefyGemsFactory is Ownable {
    using Clones for address;

    BeefyGems public instance;
    address public treasury;

    struct Season {
        uint256 id;
        address gems;
        uint256 amountOfGems;
        uint256 amountOfS;
        bool redemptionActive;
    }

    Season[] private seasons;

    event NewSeason(uint256 indexed id, uint256 amountOfGems, address gems);
    event OpenSeason(uint256 indexed id, uint256 amountOfS);
    event Redeemed(address indexed who, uint256 indexed seasonNum, uint256 amount, uint256 amountOfS);

    error RedemptionNotOpen();
    error NotEnoughS();
    
    constructor(
        address _treasury
    ) Ownable(msg.sender) {
        instance = new BeefyGems();
        treasury = _treasury;
    }

    /// @notice Create a new season
    /// @param _amountOfGems Amount of gems to be minted
    function createSeason(uint256 _amountOfGems) public onlyOwner {
        uint256 seasonNum = seasons.length + 1;

        address gems = Clones.clone(address(instance));

        string memory name = string.concat("Beefy Gems Season ", Strings.toString(seasonNum));
        string memory symbol = string.concat("beGEMS", Strings.toString(seasonNum));

        BeefyGems(gems).initialize(
            name,
            symbol,
            treasury,
            _amountOfGems
        );

        Season memory season = Season({
            id: seasonNum,
            gems: gems,
            amountOfGems: _amountOfGems,
            amountOfS: 0,
            redemptionActive: false
        });

        seasons.push(season);

        emit NewSeason(seasonNum, _amountOfGems, gems);
    }

    /// @notice Open a season for redemption
    /// @param seasonNum Season number
    function openSeasonRedemption(uint256 seasonNum) public payable onlyOwner {
        Season storage season = seasons[seasonNum - 1];
        season.redemptionActive = true;
        season.amountOfS = msg.value;

        emit OpenSeason(seasonNum, season.amountOfS);
    }
    
    /// @notice Get the number of seasons
    /// @return Number of seasons
    function numSeasons() public view returns (uint256) {
        return seasons.length;
    }

    /// @notice Get a season by season number
    /// @param _seasonNum Season number
    /// @return Season memory
    function getSeason(uint256 _seasonNum) public view returns (Season memory) {
        return seasons[_seasonNum - 1];
    }

    /// @notice Redeem gems for S
    /// @param seasonNum Season number
    /// @param _amount Amount of gems to redeem
    function redeem(uint256 seasonNum, uint256 _amount) public payable {
        Season storage season = seasons[seasonNum - 1];
        if (!season.redemptionActive) revert RedemptionNotOpen();

        uint256 r = (season.amountOfS * _amount) / season.amountOfGems;
        
        BeefyGems(season.gems).burn(_amount, msg.sender);

        (bool success, ) = msg.sender.call{value: r}("");
        if (!success) revert NotEnoughS();

        emit Redeemed(msg.sender, seasonNum, _amount, r);
    }

    /// @notice Get the price for a full share
    /// @param seasonNum Season number
    /// @return Price for a full share  
    function getPriceForFullShare(uint256 seasonNum) public view returns (uint256) {
        Season storage season = seasons[seasonNum - 1];
        if (season.amountOfGems == 0) return 0;
        return season.amountOfS * 1e18 / season.amountOfGems;
    }

    receive() external payable onlyOwner {}
}