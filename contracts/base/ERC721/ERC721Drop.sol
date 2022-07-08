// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "./ERC721DelayedReveal.sol";
import "./ERC721SignatureMint.sol";

import "../../feature/DropSinglePhase.sol";
import "../../feature/LazyMintUpdated.sol";
import "../../feature/DelayedReveal.sol";

import "../../lib/TWStrings.sol";

/**
 *      BASE:      ERC721A
 *      EXTENSION: SignatureMintERC721, DropSinglePhase
 *
 *  The `ERC721Drop` contract uses the `ERC721ABase` contract, along with the `SignatureMintERC721` and `DropSinglePhase` extension.
 *
 *  The 'signature minting' mechanism in the `SignatureMintERC721` extension is a way for a contract admin to authorize
 *  an external party's request to mint tokens on the admin's contract. At a high level, this means you can authorize 
 *  some external party to mint tokens on your contract, and specify what exactly will be minted by that external party.
 *
 *  The `drop` mechanism in the `DropSinglePhase` extension is a distribution mechanism for lazy minted tokens. It lets
 *  you set restrictions such as a price to charge, an allowlist etc. when an address atttempts to mint lazy minted tokens.
 *
 *  The `ERC721Drop` contract lets you lazy mint tokens, and distribute those lazy minted tokens via signature minting, or
 *  via the drop mechanism.
 */

contract ERC721Drop is
    ERC721SignatureMint,
    LazyMintUpdated,
    DelayedReveal,
    DropSinglePhase
{
    using TWStrings for uint256;

    /*///////////////////////////////////////////////////////////////
                            Custom Errors
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when minting the given quantity will exceed available quantity.
    error ERC721Drop__NotEnoughMintedTokens(uint256 currentIndex, uint256 quantity);

    /// @notice Emitted when sent value doesn't match the total price of tokens.
    error ERC721Drop__MustSendTotalPrice(uint256 sentValue, uint256 totalPrice);

    /// @notice Emitted when given address doesn't have transfer role.
    error ERC721Drop__NotTransferRole();

    /*///////////////////////////////////////////////////////////////
                            Constructor
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _defaultAdmin,
        string memory _name,
        string memory _symbol,
        string memory _contractURI,
        address _royaltyRecipient,
        uint128 _royaltyBps,
        address _primarySaleRecipient
    )
        ERC721SignatureMint(
            _name,
            _symbol,
            _contractURI,
            _royaltyRecipient,
            _royaltyBps,
            _primarySaleRecipient
        ) 
    {}

    /*///////////////////////////////////////////////////////////////
                    Overriden ERC 721 logic
    //////////////////////////////////////////////////////////////*/

     /**
     *  @notice         Returns the metadata URI for an NFT.
     *  @dev            See `BatchMintMetadata` for handling of metadata in this contract.
     *
     *  @param _tokenId The tokenId of an NFT.
     */
    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        uint256 batchId = getBatchId(_tokenId);
        string memory batchUri = getBaseURI(_tokenId);

        if (isEncryptedBatch(batchId)) {
            return string(abi.encodePacked(batchUri, "0"));
        } else {
            return string(abi.encodePacked(batchUri, _tokenId.toString()));
        }
    }

    /*///////////////////////////////////////////////////////////////
                Overriden signature minting logic
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice           Mints tokens according to the provided mint request.
     *
     *  @param _req       The payload / mint request.
     *  @param _signature The signature produced by an account signing the mint request.
     */
    function mintWithSignature(MintRequest calldata _req, bytes calldata _signature)
        external
        payable
        virtual
        override
        returns (address signer)
    {
        require(_req.quantity > 0, "Minting zero tokens.");

        uint256 tokenIdToMint = nextTokenIdToMint();
        require(
            tokenIdToMint + _req.quantity <= nextTokenIdToLazyMint,
            "Not enough lazy minted tokens."
        );

        // Verify and process payload.
        signer = _processRequest(_req, _signature);

        /**
         *  Get receiver of tokens.
         *
         *  Note: If `_req.to == address(0)`, a `mintWithSignature` transaction sitting in the
         *        mempool can be frontrun by copying the input data, since the minted tokens
         *        will be sent to the `_msgSender()` in this case.
         */
        address receiver = _req.to == address(0) ? msg.sender : _req.to;

        // Collect price
        collectPriceOnClaim(_req.quantity, _req.currency, _req.pricePerToken);

        // Mint tokens.
        _safeMint(receiver, _req.quantity);

        emit TokensMintedWithSignature(signer, receiver, tokenIdToMint, _req);
    }

    /*///////////////////////////////////////////////////////////////
                    Overriden lazy minting logic
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice                  Lets an authorized address lazy mint a given amount of NFTs.
     *
     *  @param _amount           The number of NFTs to lazy mint.
     *  @param _baseURIForTokens The placeholder base URI for the 'n' number of NFTs being lazy minted, where the
     *                           metadata for each of those NFTs is `${baseURIForTokens}/${tokenId}`.
     *  @param _encryptedBaseURI The encrypted base URI for the batch of NFTs being lazy minted.
     *  @return batchId          A unique integer identifier for the batch of NFTs lazy minted together.
     */
    function lazyMint(
        uint256 _amount,
        string calldata _baseURIForTokens,
        bytes calldata _encryptedBaseURI
    ) public virtual override returns (uint256 batchId) {
        if (_encryptedBaseURI.length != 0) {
            _setEncryptedBaseURI(nextTokenIdToLazyMint + _amount, _encryptedBaseURI);
        }

        return LazyMintUpdated.lazyMint(_amount, _baseURIForTokens, _encryptedBaseURI);
    }

    /*///////////////////////////////////////////////////////////////
                        Delayed reveal logic
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice       Lets an authorized address reveal a batch of delayed reveal NFTs.
     *
     *  @param _index The ID for the batch of delayed-reveal NFTs to reveal.
     *  @param _key   The key with which the base URI for the relevant batch of NFTs was encrypted.
     */
    function reveal(uint256 _index, bytes calldata _key)
        external
        returns (string memory revealedURI)
    {
        require(_canReveal(), "Not authorized");

        uint256 batchId = getBatchIdAtIndex(_index);
        revealedURI = getRevealURI(batchId, _key);

        _setEncryptedBaseURI(batchId, "");
        _setBaseURI(batchId, revealedURI);

        emit TokenURIRevealed(_index, revealedURI);
    }
    
    /*///////////////////////////////////////////////////////////////
                        Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Runs before every `claim` function call.
    function _beforeClaim(
        address,
        uint256 _quantity,
        address,
        uint256,
        AllowlistProof calldata,
        bytes memory
    ) internal view override {
        require(msg.sender == tx.origin, "BOT");
        if (nextTokenIdToMint() + _quantity > nextTokenIdToLazyMint) {
            revert ERC721Drop__NotEnoughMintedTokens(_currentIndex, _quantity);
        }
    }

    /// @dev Collects and distributes the primary sale value of NFTs being claimed.
    function collectPriceOnClaim(
        uint256 _quantityToClaim,
        address _currency,
        uint256 _pricePerToken
    ) internal override(DropSinglePhase, ERC721SignatureMint) {
        if (_pricePerToken == 0) {
            return;
        }

        uint256 totalPrice = _quantityToClaim * _pricePerToken;

        if (_currency == CurrencyTransferLib.NATIVE_TOKEN) {
            if (msg.value != totalPrice) {
                revert ERC721Drop__MustSendTotalPrice(msg.value, totalPrice);
            }
        }

        CurrencyTransferLib.transferCurrency(
            _currency,
            msg.sender,
            primarySaleRecipient(),
            totalPrice
        );
    }

    /// @dev Transfers the NFTs being claimed.
    function transferTokensOnClaim(address _to, uint256 _quantityBeingClaimed)
        internal
        override
        returns (uint256 startTokenId)
    {
        startTokenId = nextTokenIdToMint();
        _safeMint(_to, _quantityBeingClaimed);
    }

    /// @dev Checks whether primary sale recipient can be set in the given execution context.
    function _canSetPrimarySaleRecipient() internal view override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Checks whether owner can be set in the given execution context.
    function _canSetOwner() internal view override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Checks whether royalty info can be set in the given execution context.
    function _canSetRoyaltyInfo() internal view override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Checks whether contract metadata can be set in the given execution context.
    function _canSetContractURI() internal view override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Checks whether platform fee info can be set in the given execution context.
    function _canSetClaimConditions() internal view override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Returns whether lazy minting can be done in the given execution context.
    function _canLazyMint() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    /// @dev Checks whether NFTs can be revealed in the given execution context.
    function _canReveal() internal view virtual returns (bool) {
        return msg.sender == owner();
    }

    /*///////////////////////////////////////////////////////////////
                        Miscellaneous
    //////////////////////////////////////////////////////////////*/

    function _dropMsgSender() internal view virtual override returns (address) {
        return msg.sender;
    }

    function mint(
        address,
        uint256,
        string memory,
        bytes memory
    ) public virtual override {
        revert("Not authorized to mint.");
    }
}