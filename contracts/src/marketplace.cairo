// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts for Cairo ^0.15.0

use starknet::ContractAddress;

#[derive(Copy, Drop, Serde, PartialEq)]
pub enum ROLES {
    PRODUCER,
    ROASTER,
    CAMBIATUS,
    COFIBLOCKS,
    COFOUNDER,
    CONSUMER,
}

#[derive(Drop, Serde, starknet::Store)]
    struct ListedProduct {
        token_id: u256,
        stock: u256,
        sells: u256,
        price_usdc: u256,
        price_usdc_with_fee: u256,
        is_producer: bool,
        owner: ContractAddress,
        associated_producer: ContractAddress,
        short_description: felt252,
        is_available: bool,
    }


#[starknet::interface]
pub trait IMarketplace<ContractState> {
    fn assign_role(ref self: ContractState, role: ROLES, assignee: ContractAddress);
    fn account_has_role(self: @ContractState, role: ROLES, account: ContractAddress) -> bool;
    fn account_revoke_role(ref self: ContractState, role: ROLES, revokee: ContractAddress);
    fn buy_product(ref self: ContractState, token_id: u256, token_amount: u256, buyer: ContractAddress);
    fn create_product(
        ref self: ContractState, 
        initial_stock: u256, 
        price: u256, 
        associated_producer: ContractAddress, 
        short_description: felt252
    ) -> u256;
    fn add_stock(ref self: ContractState, token_id: u256, amount: u256);
    fn get_product(self: @ContractState, token_id: u256) -> ListedProduct;
    fn delete_product(ref self: ContractState, token_id: u256);
    fn withdraw_distribution_balance(ref self: ContractState, role: ROLES);
    fn withdraw(ref self: ContractState, amount: u256, recipient: ContractAddress);
    fn withdraw_seller_balance(ref self: ContractState);
    fn get_seller_balance(self: @ContractState, wallet_address: ContractAddress) -> u256;
    fn get_tokens_by_holder(self: @ContractState, wallet_address: ContractAddress) -> Array<u256>;
}

#[starknet::contract]
mod Marketplace {
    use contracts::cofi_collection::{ICofiCollectionDispatcher, ICofiCollectionDispatcherTrait};
    use contracts::distribution::{IDistributionDispatcher, IDistributionDispatcherTrait};
    use openzeppelin::access::accesscontrol::{AccessControlComponent, DEFAULT_ADMIN_ROLE};
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::token::erc1155::erc1155_receiver::ERC1155ReceiverComponent;
    use openzeppelin::interfaces::token::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::upgrades::UpgradeableComponent;
    use openzeppelin::interfaces::upgrades::IUpgradeable;
    use starknet::event::EventEmitter;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess, StoragePathEntry, Vec, MutableVecTrait, VecTrait
    };
    use starknet::{ClassHash, ContractAddress, get_caller_address, get_contract_address};
    use super::{ROLES, ListedProduct};

    component!(
        path: ERC1155ReceiverComponent, storage: erc1155_receiver, event: ERC1155ReceiverEvent,
    );
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    // ERC1155Receiver
    #[abi(embed_v0)]
    impl ERC1155ReceiverImpl =
        ERC1155ReceiverComponent::ERC1155ReceiverImpl<ContractState>;
    impl ERC1155ReceiverInternalImpl = ERC1155ReceiverComponent::InternalImpl<ContractState>;

    // SRC5
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    // Access Control
    #[abi(embed_v0)]
    impl AccessControlImpl =
        AccessControlComponent::AccessControlImpl<ContractState>;
    impl AccessControlInternalImpl = AccessControlComponent::InternalImpl<ContractState>;

    // Upgradeable
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc1155_receiver: ERC1155ReceiverComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        accesscontrol: AccessControlComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        distribution: IDistributionDispatcher,
        market_fee: u256,
        listed_products: Map<u256, ListedProduct>,
        cofi_collection_address: ContractAddress,
        seller_claim_balances: Map<ContractAddress, u256>,
        current_token_id: u256,
        usdc_address: ContractAddress,
        token_holders: Map<ContractAddress, Vec<u256>>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC1155ReceiverEvent: ERC1155ReceiverComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        DeleteProduct: DeleteProduct,
        CreateProduct: CreateProduct,
        UpdateStock: UpdateStock,
        BuyProduct: BuyProduct,
        BuyBatchProducts: BuyBatchProducts,
        PaymentSeller: PaymentSeller,
        AssignedRole: AssignedRole,
        RevokedRole: RevokedRole,
    }
    // Emitted when a product is unlisted from the Marketplace
    #[derive(Drop, PartialEq, starknet::Event)]
    struct DeleteProduct {
        token_id: u256,
    }

    // Emitted when a product is listed to the Marketplace
    #[derive(Drop, PartialEq, starknet::Event)]
    struct CreateProduct {
        token_id: u256,
        initial_stock: u256,
        owner: ContractAddress,
        price: u256,
    }

    // Emitted when the stock of a product is updated
    #[derive(Drop, PartialEq, starknet::Event)]
    struct UpdateStock {
        token_id: u256,
        new_stock: u256,
    }

    // Emitted when a product is bought from the Marketplace
    #[derive(Drop, PartialEq, starknet::Event)]
    struct BuyProduct {
        token_id: u256,
        amount: u256,
        buyer: ContractAddress,
    }

    // Emitted when a batch of products is bought from the Marketplace
    #[derive(Drop, PartialEq, starknet::Event)]
    struct BuyBatchProducts {
        token_ids: Span<u256>,
        token_amount: Span<u256>,
        buyer: ContractAddress,
    }

    // Emitted when the seller gets their tokens from a sell
    #[derive(Drop, PartialEq, starknet::Event)]
    struct PaymentSeller {
        token_ids: Span<u256>,
        seller: ContractAddress,
        payment: u256,
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct AssignedRole {
        role: felt252,
        assignee: ContractAddress,
    }

    #[derive(Drop, PartialEq, starknet::Event)]
    struct RevokedRole {
        role: felt252,
        revokee: ContractAddress,
    }

    ///
    /// Constructor.
    /// # Arguments
    /// * `cofi_collection_address` - The address of the CofiCollection contract
    /// * `ekubo_address` - The address of the Ekubo contract
    /// * `admin` - The address of the admin role
    /// * `market_fee` - The fee that the marketplace will take from the sales
    /// * `base_uri` - The base uri for the NFTs metadata. Should contain `{id}` so that metadata
    /// gets
    ///    replace per each token id. Example: https://example.com/metadata/{id}.json
    ///
    #[constructor]
    fn constructor(
        ref self: ContractState,
        cofi_collection_address: ContractAddress,
        distribution_address: ContractAddress,
        usdc_address: ContractAddress,
        admin: ContractAddress,
        market_fee: u256,
    ) {
        self.erc1155_receiver.initializer();
        self.accesscontrol.initializer();
        self.accesscontrol._grant_role(DEFAULT_ADMIN_ROLE, admin);
        self.cofi_collection_address.write(cofi_collection_address);
        self.usdc_address.write(usdc_address);
        self.distribution.write(IDistributionDispatcher { contract_address: distribution_address });
        self.market_fee.write(market_fee);
        self.current_token_id.write(1);
    }

    #[abi(embed_v0)]
    impl MarketplaceImpl of super::IMarketplace<ContractState> {
        fn assign_role(ref self: ContractState, role: ROLES, assignee: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            self.accesscontrol._grant_role(self.role_selector(role), assignee);
            self.emit(AssignedRole { role: self.role_selector(role), assignee: assignee });
        }

        fn account_has_role(self: @ContractState, role: ROLES, account: ContractAddress) -> bool {
            self.accesscontrol.has_role(self.role_selector(role), account)
        }

        fn account_revoke_role(ref self: ContractState, role: ROLES, revokee: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            self.accesscontrol._revoke_role(self.role_selector(role), revokee);
            self.emit(RevokedRole { role: self.role_selector(role), revokee: revokee });
        }

        fn get_product(self: @ContractState, token_id: u256) -> ListedProduct {
            self.listed_products.read(token_id)
        }

        fn buy_product(ref self: ContractState, token_id: u256, token_amount: u256, buyer: ContractAddress) {
            let mut listed_product = self.listed_products.read(token_id);
            let stock = listed_product.stock;
            assert(stock >= token_amount, 'Not enough stock');
            assert(listed_product.is_available, 'Product not available');

            let mut producer_fee = listed_product.price_usdc * token_amount;
            let mut total_usdc = listed_product.price_usdc_with_fee * token_amount;
            // Buyer and payer can be different (e.g. using stripe)
            self.pay_for_product(total_usdc, get_caller_address());
            self.emit(BuyProduct { token_id, amount: token_amount, buyer: buyer });

            // Transfer the nft products
            self.transfer_nfts(buyer, token_id, token_amount);

            self.assign_consumer_role(buyer);

            // Register payment to the producer
            self.seller_claim_balances.write(
                listed_product.owner, self.seller_claim_balances.read(listed_product.owner) + producer_fee
            );
            self.emit(PaymentSeller { 
                token_ids: array![token_id].span(), seller: listed_product.owner, payment: producer_fee 
            });

            let new_stock = stock - token_amount;
            listed_product.stock = new_stock;
            listed_product.sells = listed_product.sells + token_amount;

            // Register purchase in the distribution contract
            self.register_buy_for_distribution(@listed_product, buyer, token_amount);

            self.listed_products.write(token_id, listed_product);
            self.emit(UpdateStock { token_id, new_stock });

        }

        ///
        /// Adds a new product to the marketplace
        /// Arguments:
        /// * `initial_stock` - The amount of stock that the product will have
        /// * `price` - The price of the product per unity expresed in usdc (1e-6 usdc)
        fn create_product(
            ref self: ContractState,
            initial_stock: u256,
            price: u256,
            associated_producer: ContractAddress,
            short_description: felt252,
        ) -> u256 {
            let seller = get_caller_address();
            let is_producer = self.seller_is_producer(seller);

            assert(initial_stock > 0, 'Initial stock cannot be 0');
            assert(initial_stock <= 1000, 'Initial_stock max 1000');

            let token_id = self.current_token_id.read();
            self.mint_nfts(token_id, initial_stock);

            self.current_token_id.write(token_id + 1);
            let price_with_fee = price + self.calculate_fee(price, self.market_fee.read());
            let listed_product = ListedProduct {
                token_id,
                stock: initial_stock,
                price_usdc: price,
                price_usdc_with_fee: price_with_fee,
                is_producer,
                owner: seller,
                associated_producer,
                short_description,
                is_available: true,
                sells: 0,
            };
            self.listed_products.write(token_id, listed_product);
            self.emit(CreateProduct { token_id, initial_stock: initial_stock, owner: seller, price: price_with_fee });
            token_id
        }

        fn add_stock(ref self: ContractState, token_id: u256, amount: u256) {
            let seller = get_caller_address();
            let mut listed_product = self.listed_products.read(token_id);
            assert(listed_product.owner == seller, 'Not your product');
            assert(amount > 0, 'Amount cannot be 0');
            assert(amount <= 1000, 'Amount max 1000');
            assert(listed_product.is_available, 'Product not available');

            // Mint more 1155 tokens for this token_id
            self.mint_nfts(token_id, amount);
        
            // Update marketplace stock
            let new_stock = listed_product.stock + amount;
            listed_product.stock = new_stock;
            self.listed_products.write(token_id, listed_product);
            self.emit(UpdateStock { token_id, new_stock: new_stock });
        }

        fn delete_product(ref self: ContractState, token_id: u256) {
            let seller = get_caller_address();
            self.seller_is_producer(seller);
            let mut listed_product = self.listed_products.read(token_id);
            assert(listed_product.owner == seller, 'Not your product');

            let cofi_collection = ICofiCollectionDispatcher {
                contract_address: self.cofi_collection_address.read(),
            };
            let token_holder = get_contract_address();
            let amount_tokens = cofi_collection.balance_of(token_holder, token_id);
            cofi_collection.burn(token_holder, token_id, amount_tokens);
            listed_product.is_available = false;
            listed_product.stock = 0;
            self.listed_products.write(token_id, listed_product);
            self.emit(DeleteProduct { token_id });
        }

        fn withdraw_distribution_balance(ref self: ContractState, role: ROLES) {
            self.accesscontrol.assert_only_role(self.role_selector(role));
            let recipient = get_caller_address();
            let distribution = self.distribution.read();
            let claim_balance = match role {
                ROLES::CONSUMER => distribution.coffee_lover_claim_balance(recipient),
                ROLES::PRODUCER => distribution.producer_claim_balance(recipient),
                ROLES::ROASTER => distribution.roaster_claim_balance(recipient),
                ROLES::CAMBIATUS => distribution.cambiatus_claim_balance(),
                ROLES::COFIBLOCKS => distribution.cofiblocks_claim_balance(),
                ROLES::COFOUNDER => distribution.cofounder_claim_balance(recipient),
            };
            self.withdraw_usdc(claim_balance, recipient);
            
            match role {
                ROLES::CONSUMER => distribution.coffee_lover_claim_reset(recipient),
                ROLES::PRODUCER => distribution.producer_claim_reset(recipient),
                ROLES::ROASTER => distribution.roaster_claim_reset(recipient),
                ROLES::CAMBIATUS => distribution.cambiatus_claim_reset(),
                ROLES::COFIBLOCKS => distribution.cofiblocks_claim_reset(),
                ROLES::COFOUNDER => distribution.cofounder_claim_reset(recipient),
            }
        }

        fn withdraw(ref self: ContractState, amount: u256, recipient: ContractAddress) {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            self.withdraw_usdc(amount, recipient);
        }

        fn withdraw_seller_balance(ref self: ContractState) {
            // Producers/roasters should call this function to receive their payment
            let balance = self.seller_claim_balances.read(get_caller_address());
            self.withdraw_usdc(balance, get_caller_address());
            self.seller_claim_balances.write(get_caller_address(), 0);
        }

        fn get_seller_balance(self: @ContractState, wallet_address: ContractAddress) -> u256 {
            // Producers/roasters can read their claim payment from here
            self.seller_claim_balances.read(wallet_address)
        }

        fn get_tokens_by_holder(self: @ContractState, wallet_address: ContractAddress) -> Array<u256> {
            let len_tokens = self.token_holders.entry(wallet_address).len();
            let mut user_tokens = array![];

            for index in 0..len_tokens {
                user_tokens.append(self.token_holders.entry(wallet_address).at(index).read());
            };

            user_tokens
        }
    }

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            // This function can only be called by the owner
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            // Replace the class hash upgrading the contract
            self.upgradeable.upgrade(new_class_hash);
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {

        fn mint_nfts(ref self: ContractState, token_id: u256, amount: u256) {
            let cofi_collection = ICofiCollectionDispatcher {
                contract_address: self.cofi_collection_address.read(),
            };
            cofi_collection.mint(get_contract_address(), token_id, amount, array![].span());
        }

        fn pay_for_product(ref self: ContractState, total_usdc: u256, buyer: ContractAddress) {
            let usdc_dispatcher = IERC20Dispatcher { contract_address: self.usdc_address.read() };
            let contract_address = get_contract_address();
            assert(usdc_dispatcher.balance_of(buyer) >= total_usdc, 'insufficient funds');
            assert(usdc_dispatcher.allowance(buyer, contract_address) >= total_usdc, 'insufficient allowance');
            let success = usdc_dispatcher.transfer_from(buyer, contract_address, total_usdc);
            assert(success, 'Error transferring tokens');
        }

        fn transfer_nfts(ref self: ContractState, receiver: ContractAddress, token_id: u256, amount: u256) {
            let cofi_collection = ICofiCollectionDispatcher {
                contract_address: self.cofi_collection_address.read(),
            };
            cofi_collection
                .safe_transfer_from(
                    get_contract_address(), receiver, token_id, amount, array![0].span(),
                );

            self.token_holders.entry(receiver).push(token_id);
        }

        fn assign_consumer_role(ref self: ContractState, consumer: ContractAddress) {
            if (!self.accesscontrol.has_role(self.role_selector(ROLES::CONSUMER), consumer)) {
                self.accesscontrol._grant_role(self.role_selector(ROLES::CONSUMER), consumer);
            }
        }

        fn register_buy_for_distribution(
            ref self: ContractState, listed_product: @ListedProduct, buyer: ContractAddress, amount: u256
        ) {
            let distribution = self.distribution.read();
            let profit = (*(listed_product.price_usdc_with_fee) - *(listed_product.price_usdc)) * amount;
            let producer_fee = *(listed_product.price_usdc) * amount;
            let seller = *(listed_product.owner);
            let is_producer = *(listed_product.is_producer);
            let associated_producer = *(listed_product.associated_producer);
            distribution.register_purchase(
                buyer, seller, is_producer, associated_producer, producer_fee, profit
            );
        }

        fn withdraw_usdc(ref self: ContractState, amount: u256, recipient: ContractAddress) {
            assert(amount > 0, 'No tokens to claim');

            let usdc_token_dispatcher = IERC20Dispatcher {
                contract_address: self.usdc_address.read(),
            };
            let marketplace_balance = usdc_token_dispatcher.balance_of(get_contract_address());
            assert(amount <= marketplace_balance, 'Contract insufficient balance');
            let transfer = usdc_token_dispatcher.transfer(recipient, amount);
            assert(transfer, 'Error claiming');
        }

        // Amount is the total amount
        // BPS is the percentage you want to calculate. (Example: 2.5% = 250bps, 7,48% = 748bps)
        // Use example:
        // Calculate the 3% fee of 250 STRK
        // calculate_fee(250, 300) = 7.5
        fn calculate_fee(self: @ContractState, amount: u256, bps: u256) -> u256 {
            assert((amount * bps) >= 10_000, 'Fee too low');
            amount * bps / 10_000
        }

        fn role_selector(self: @ContractState, role: ROLES) -> felt252 {
            match role {
                ROLES::PRODUCER => selector!("PRODUCER"),
                ROLES::ROASTER => selector!("ROASTER"),
                ROLES::CAMBIATUS => selector!("CAMBIATUS"),
                ROLES::COFIBLOCKS => selector!("COFIBLOCKS"),
                ROLES::COFOUNDER => selector!("COFOUNDER"),
                ROLES::CONSUMER => selector!("CONSUMER"),
            }
        }

        fn seller_is_producer(ref self: ContractState, caller: ContractAddress) -> bool {
            let is_producer = self.accesscontrol.has_role(self.role_selector(ROLES::PRODUCER), caller);
            let is_roaster = self.accesscontrol.has_role(self.role_selector(ROLES::ROASTER), caller);
            assert(is_producer || is_roaster, 'Caller is not a seller');
            is_producer
        }
    }
}
