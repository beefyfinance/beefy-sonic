#!/bin/bash

# Store the original BeefySonic.sol
cp contracts/BeefySonic.sol contracts/BeefySonic.sol.backup

# Counters for mutants
total=0
killed=0
survived=0

# Function to restore original file
restore_original() {
    cp contracts/BeefySonic.sol.backup contracts/BeefySonic.sol
    rm contracts/BeefySonic.sol.backup
}

# Trap Ctrl+C to ensure we restore the original file
trap restore_original EXIT

# Loop through each mutant directory
for mutant_dir in gambit_out/mutants/*/; do
    mutant_num=$(basename "$mutant_dir")
    echo -n "Testing mutant $mutant_num... "
    
    # Copy mutant to contracts directory
    cp "${mutant_dir}/contracts/BeefySonic.sol" contracts/BeefySonic.sol
    
    # Run forge test
    if forge test -vv &>/dev/null; then
        echo "⚠️  Mutant $mutant_num SURVIVED (tests passed) - potential test coverage gap!"
        ((survived++))
    else
        echo "✅ Mutant $mutant_num was killed (tests failed) - good!"
        rm -rf "$mutant_dir"
        ((killed++))
    fi
    
    ((total++))
done

# Print summary
echo ""
echo "Mutation Testing Complete!"
echo "------------------------"
echo "Total mutants tested: $total"
echo "Killed mutants (good): $killed"
echo "Surviving mutants (test gaps): $survived"
echo "Kill rate: $(( (killed * 100) / total ))%"
echo ""
echo "The remaining mutants in gambit_out/mutants/ are the ones that survived (test gaps)"

# Restore original file
restore_original 