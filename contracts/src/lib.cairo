mod cofi_collection;
mod distribution;
mod marketplace;
mod swap;

#[cfg(test)]
mod test {
    mod test_cofi_collection;
    mod test_distribution;
    mod test_marketplace;
    mod test_swap;
}

#[cfg(feature: 'mock_contracts')]
mod mock_contracts {
    mod mock_usdc;
}
