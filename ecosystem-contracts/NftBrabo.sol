// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

contract NftBrabo is ERC721 {

    error MoodNft__CantFlipMoodIfNotOwner();
    error MoodNft__NotAuthorizedToMint();
    error MoodNft__TokenDoesNotExist();
    error MoodNft__AlreadyHasNft();
    
    uint256 private s_tokenIdCounter;
    string private s_bronzeSvgUriimage;
    string private s_silverSvgUriimage;
    string private s_goldSvgUriimage;
    
    address public immutable i_owner;
    address public s_minterContract;

    mapping(uint256 => MOOD) private s_tokenIdtoMood;
    mapping(address => uint256) private s_ownerToTokenId;
    mapping(address => bool) private s_hasNft;

    event TierUpgraded(uint256 indexed tokenId, address indexed owner, MOOD newTier);

    enum MOOD {
        BRONZE,
        SILVER,
        GOLD
    }
    

    modifier onlyOwner() {
        require(msg.sender == i_owner, "Not owner");
        _;
    }

    modifier onlyMinter() {
        if (msg.sender != s_minterContract && msg.sender != i_owner) {
            revert MoodNft__NotAuthorizedToMint();
        }
        _;
    }

    constructor(string memory bronzeSvg, string memory silverSvg, string memory goldSvg) ERC721("BraboNft", "BNFT") {
        s_tokenIdCounter = 0;
        s_bronzeSvgUriimage= bronzeSvg;
        s_silverSvgUriimage = silverSvg;
        s_goldSvgUriimage = goldSvg;
        i_owner = msg.sender;
    }

    function setMinterContract(address _minterContract) external onlyOwner {
        s_minterContract = _minterContract;
    }


    function mintNftTo(address recipient) public onlyMinter {
        require(!s_hasNft[recipient], "Address already has an NFT");
        _safeMint(recipient, s_tokenIdCounter);
        s_tokenIdtoMood[s_tokenIdCounter] = MOOD.BRONZE;
        s_ownerToTokenId[recipient] = s_tokenIdCounter;
        s_hasNft[recipient] = true;
        s_tokenIdCounter++;
    }

    function _baseURI() internal pure override returns (string memory) {
        return "data:application/json;base64,";
    }


   function getMoodString(uint256 tokenId) public view returns (string memory) {
        MOOD mood = s_tokenIdtoMood[tokenId];
        if (mood == MOOD.GOLD) return "Gold";
        if (mood == MOOD.SILVER) return "Silver";
        return "Bronze";
    }

    function upgradeTierBasedOnFunding(address user, uint256 fundingAmountUsd) external onlyMinter {
        
        if (!s_hasNft[user]) {
            return;
        }
        
        uint256 tokenId = s_ownerToTokenId[user];
        
        MOOD newTier;
        //uint256 fundingInDollars = fundingAmountUsd / 1e18;
        
        if (fundingAmountUsd >= 100 * 10 ** 18) {
            newTier = MOOD.GOLD;
        } else if (fundingAmountUsd >= 50 * 10 ** 18) {
            newTier = MOOD.SILVER;
        } else {
            newTier = MOOD.BRONZE;
        }

        MOOD currentTier = s_tokenIdtoMood[tokenId];
        
        if (newTier > currentTier) {
            s_tokenIdtoMood[tokenId] = newTier;
            emit TierUpgraded(tokenId, user, newTier);
        }
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");


        string memory imageURI;

        if(s_tokenIdtoMood[tokenId] == MOOD.GOLD){
            imageURI = s_goldSvgUriimage;
        } else if (s_tokenIdtoMood[tokenId] == MOOD.SILVER) {
            imageURI = s_silverSvgUriimage;
        } else {
            imageURI = s_bronzeSvgUriimage;
        }

        return string(
             abi.encodePacked(
                 _baseURI(),
                 Base64.encode(
                     bytes(
                         abi.encodePacked(
                             '{"name":"',
                             name(),
                             '", "description":"A reactive NFT that reflects how BRABO you are, three tiers available: Bronze, Silver and Gold", ',
                             '"attributes": [{"trait_type": "Tier", "value": "', getMoodString(tokenId), '"}], "image":"',
                             imageURI,
                             '"}'
                         )
                     )
                 )  
             )
         );
    }

    function getTotalSupply() external view returns (uint256) {
        return s_tokenIdCounter;
    }

    function getTokenIdByOwner(address owner) external view returns (uint256) {
        if (!s_hasNft[owner]) {
            revert MoodNft__TokenDoesNotExist();
        }
        return s_ownerToTokenId[owner];
    }


    
    function getUserTier(address user) external view returns (uint256) {
        if (!s_hasNft[user]) {
            revert MoodNft__TokenDoesNotExist();
        }

        uint256 tokenId = s_ownerToTokenId[user];
        MOOD mood = s_tokenIdtoMood[tokenId];

        return uint256(mood); // Returns 0=Bronze, 1=Silver, 2=Gold
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
    address from = _ownerOf(tokenId);
    
    if (from != address(0) && to != address(0)) {
        s_hasNft[from] = false;
        delete s_ownerToTokenId[from];
        
        s_hasNft[to] = true;
        s_ownerToTokenId[to] = tokenId;
    }
    
    return super._update(to, tokenId, auth);    
    }

}