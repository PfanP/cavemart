// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IERC721}                from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

import {SafeTransferLib, ERC20} from "lib/solmate/src/utils/SafeTransferLib.sol";

import {FullMath}               from "./FullMath.sol";

contract FixedOrderMarket {

    //////////////////////////////////////////////////////////////////////
    // IMMUTABLE STORAGE
    //////////////////////////////////////////////////////////////////////

    uint256 internal constant FEE_DIVISOR = 1e4;

    uint256 internal immutable INITIAL_CHAIN_ID;

    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    // TODO REDO THIS
    bytes32 internal immutable FULFILL_TYPEHASH = 0xdb2cdea11e430f3cbb4cdb7115691ed4cf04ff65eafd8dc6394cb4548b074398;

    //////////////////////////////////////////////////////////////////////
    // MUTABLE STORAGE
    //////////////////////////////////////////////////////////////////////

    address public feeAddress = msg.sender;

    mapping(address => uint256) public collectionFee;

    mapping(address => bool) public allowed;

    mapping(address => uint256) public nonces;

    //////////////////////////////////////////////////////////////////////
    // CONSTRUCTION
    //////////////////////////////////////////////////////////////////////

    constructor() {
        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();
    }

    //////////////////////////////////////////////////////////////////////
    // USER ACTION EVENTS
    //////////////////////////////////////////////////////////////////////
    
    event OrderFulfilled(
        address indexed seller,
        address indexed erc721,
        address indexed erc20,
        uint256 tokenId,
        uint256 price,
        uint256 deadline
    );

    //////////////////////////////////////////////////////////////////////
    // USER ACTIONS
    //////////////////////////////////////////////////////////////////////

    // @notice              
    //
    // @param seller        The address of the account that wants to sell their 
    //                      'erc721' in exchange for 'price' denominated in 'erc20'
    //
    // @param erc721        The address of a contract that follows the ERC-721 standard.
    //                      Also the address of the collection that holds the token that 
    //                      you're purchasing.
    //
    // @param erc20         The address of a contract that follows the ERC-20 standard.
    //                      Also the address of the token that the seller wants in exchange
    //                      for their 'erc721'
    //
    // @param tokenId       The 'erc721' token identification number, 'tokenId'.
    //
    // @param price         The amount of 'erc20' that the 'seller' wants in exchange for
    //                      their 'erc721'
    //
    // @param deadline      The time set to be the expiration for the order
    //
    // @param v             signature
    //
    // @param r             signature
    //
    // @param s             signature
    function fulfill(
        address seller,
        address erc721,
        address erc20,
        uint256 tokenId,
        uint256 price,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable {

        // Make sure both the 'erc721' and the 'erc20' wanted in exchange are both allowed.
        require(allowed[erc721] && allowed[erc20], "notWhitelisted()");

        // Make sure the deadline the 'seller' has specified has not elapsed.
        require(deadline >= block.timestamp, "orderExpired()");

        // Cache nonce in advance in order to avoid stack overflow errors.
        uint256 nonce = nonces[seller];

        address recoveredAddress = ecrecover(
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(FULFILL_TYPEHASH, seller, erc721, erc20, tokenId, price, nonce, deadline))
                )
            ), 
            v, 
            r, 
            s
        );

        // Make sure the recovered address is not NULL, and is equal to the 'seller'.
        require(recoveredAddress != address(0) && recoveredAddress == seller, "invalidSignature()");
    
        // Increment 'seller's nonce by one, unchecked because nonce increasing will not reasonably overflow.
        unchecked { nonces[seller]++; }
        
        // Cache the fee that's going to be charged to the 'seller'.
        uint256 fee = FullMath.mulDiv(price, collectionFee[erc721], FEE_DIVISOR);

        // If 'erc20' is NULL, we assume the seller wants native ETH.
        if (erc20 == address(0)) {

            // Make sure the amount of ETH sent is at least the price specified.
            require(msg.value >= price, "insufficientMsgValue()");

            // Transfer msg.value minus 'fee' from this contract to 'seller'
            SafeTransferLib.safeTransferETH(recoveredAddress, price - fee);
            
            // TODO manually withdraw eth
            // // Tranfer remaining balance to 'feeAddress'
            // if (fee > 0 ) SafeTransferLib.safeTransferETH(feeAddress, address(this).balance);

            // If 'erc20' is not NULL, we assume the seller wants a ERC20.
        } else {

            // Transfer 'erc20' 'price' minus 'fee' from caller to 'seller'.
            SafeTransferLib.safeTransferFrom(ERC20(erc20), msg.sender, recoveredAddress, price - fee);
            
            // Transfer 'fee' to 'feeAddress'.
            SafeTransferLib.safeTransferFrom(ERC20(erc20), msg.sender, feeAddress, fee);
        
        }

        // Transfer 'erc721' from 'seller' to msg.sender/caller.
        IERC721(erc721).safeTransferFrom(recoveredAddress, msg.sender, tokenId);

        // Emit event since state was mutated.
        emit OrderFulfilled(seller, erc721, erc20, tokenId, price, deadline);
    }

    //////////////////////////////////////////////////////////////////////
    // MANAGMENT EVENTS
    //////////////////////////////////////////////////////////////////////

    event FeeAddressUpdated(
        address newFeeAddress
    );
    
    event CollectionFeeUpdated(
        address collection, 
        uint256 percent
    );
    
    event WhitelistUpdated(
        address token,
        bool whitelisted
    );
    
    //////////////////////////////////////////////////////////////////////
    // MANAGMENT MODIFIERS
    //////////////////////////////////////////////////////////////////////

    modifier access() {
        require(msg.sender == feeAddress, "ACCESS");
        _;
    }

    //////////////////////////////////////////////////////////////////////
    // MANAGMENT ACTIONS
    //////////////////////////////////////////////////////////////////////

    function updateFeeAddress(address account) external access {
        feeAddress = account;
        emit FeeAddressUpdated(account);
    }

    function updateCollectionFee(address collection, uint256 percent) external access {
        collectionFee[collection] = percent;
        emit CollectionFeeUpdated(collection, percent);
    }

    function updateWhitelist(address token) external access {
        bool whitelisted = !allowed[token];
        allowed[token] = whitelisted;
        emit WhitelistUpdated(token, whitelisted);
    }

    //////////////////////////////////////////////////////////////////////
    // EXTERNAL VIEW
    //////////////////////////////////////////////////////////////////////

    function verifyOrder(
        address seller,
        address buyer,
        address erc721,
        address erc20,
        uint256 tokenId,
        uint256 price,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external view returns (bool valid) {
        
        // Make sure both the 'erc721' and the 'erc20' wanted in exchange are both allowed.
        if (!allowed[erc721] || !allowed[erc20]) return false;

        // Make sure the deadline the 'seller' has specified has not elapsed.
        if (deadline < block.timestamp) return false;

        // Make sure the 'seller' still owns the 'erc721' being offered.
        if (IERC721(erc721).ownerOf(tokenId) != seller) return false;

        // Make sure the buyer has 'price' denominated in 'erc20' if 'erc20' is not native ETH.
        if (erc20 != address(0)) {
            if (ERC20(erc20).balanceOf(buyer) < price && buyer != address(0)) return false;
        }

        // Cache nonce in advance in order to avoid stack overflow errors.
        uint256 nonce = nonces[seller];

        address recoveredAddress = ecrecover(
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(FULFILL_TYPEHASH, seller, erc721, erc20, tokenId, price, nonce, deadline))
                )
            ), 
            v, 
            r, 
            s
        );

        // Make sure the recovered address is not NULL, and is equal to the 'seller'.
        if (recoveredAddress == address(0) || recoveredAddress != seller) return false;

        return true;
    }

    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : computeDomainSeparator();
    }

    //////////////////////////////////////////////////////////////////////
    // INTERNAL VIEW
    //////////////////////////////////////////////////////////////////////

    function computeDomainSeparator() internal view virtual returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes("Fixed Order Market")),
                    keccak256("1"),
                    block.chainid,
                    address(this)
                )
            );
    }
}