use core::fmt::{Display, Formatter, Error};
use core::num::traits::Bounded;
use crate::parent_hash;
use utils::{numeric::u64_next_power_of_two, sort::bubble_sort};

/// Utreexo inclusion proof for multiple outputs.
/// Compatible with https://github.com/utreexo/utreexo
#[derive(Drop, Copy)]
pub struct UtreexoBatchProof {
    /// List of sibling nodes required to calculate the roots.
    pub proof: Span<felt252>,
    /// Indices of leaves to be deleted (ordered starting from 0, left to right).
    pub targets: Span<u64>,
}

impl UtreexoBatchProofDisplay of Display<UtreexoBatchProof> {
    fn fmt(self: @UtreexoBatchProof, ref f: Formatter) -> Result<(), Error> {
        let mut targets: ByteArray = Default::default();
        let mut proofs: ByteArray = Default::default();
        for proof in *self.proof {
            proofs.append(@format!("{},", proof));
        };
        for target in *self.targets {
            targets.append(@format!("{},", target));
        };
        let str: ByteArray = format!(
            "UtreexoBatchProof {{ proof: [{}], leaf_index: [{}] }}", @targets, @proofs
        );
        f.buffer.append(@str);
        Result::Ok(())
    }
}

#[generate_trait]
pub impl UtreexoBatchProofImpl of UtreexoBatchProofTrait {
    /// Computes a set of roots given a proof and leaves hashes.
    fn compute_roots(
        self: @UtreexoBatchProof, mut del_hashes: Span<felt252>, num_leaves: u64,
    ) -> Result<Span<felt252>, ByteArray> {
        // Where all the parent hashes we've calculated in a given row will go to.
        let mut calculated_root_hashes: Array<felt252> = array![];
        // Target leaves
        let mut leaf_nodes: Array<(u64, felt252)> = array![];

        let mut inner_result = Result::Ok((array![].span()));

        // Append targets with their hashes.
        let mut positions = *self.targets;
        while let Option::Some(rhs) = del_hashes.pop_front() {
            if let Option::Some(lhs) = positions.pop_front() {
                leaf_nodes.append((*lhs, *rhs));
            } else {
                inner_result = Result::Err("Not enough targets in the proof.");
            }
        };

        let mut leaf_nodes: Array<(u64, felt252)> = bubble_sort(leaf_nodes.span());

        // Proof nodes.
        let mut sibling_nodes: Array<felt252> = (*self.proof).into();
        // Queue of computed intermediate nodes.
        let mut computed_nodes: Array<(u64, felt252)> = array![];
        // Actual length of the current row.
        let mut actual_row_len: u64 = num_leaves;
        // Length of the "padded" row which is always power of two.
        let mut row_len: u64 = u64_next_power_of_two(num_leaves);
        // Total padded length of processed rows (excluding the current one).
        let mut row_len_acc: u64 = 0;
        // Next position of the target leaf and the leaf itself.
        let (mut next_leaf_pos, mut next_leaf) = leaf_nodes.pop_front().unwrap();
        // Next computed node.
        let mut next_computed: felt252 = 0;
        // Position of the next computed node.
        let mut next_computed_pos: u64 = Bounded::<u64>::MAX;

        while row_len != 0 {
            let (pos, node) = if next_leaf_pos < next_computed_pos {
                let res = (next_leaf_pos, next_leaf);
                let (a, b) = leaf_nodes.pop_front().unwrap_or((Bounded::<u64>::MAX, 0));
                next_leaf_pos = a;
                next_leaf = b;
                res
            } else if next_computed_pos != Bounded::<u64>::MAX {
                let res = (next_computed_pos, next_computed);
                let (a, b) = computed_nodes.pop_front().unwrap_or((Bounded::<u64>::MAX, 0));
                next_computed_pos = a;
                next_computed = b;
                res
            } else {
                // Out of nodes, terminating here.
                break;
            };

            // If we are beyond current row, level up.
            while pos >= row_len_acc + row_len {
                row_len_acc += row_len;
                row_len /= 2;
                actual_row_len /= 2;

                if row_len == 0 {
                    inner_result =
                        Result::Err(
                            format!("Position {pos} is out of the forest range {row_len_acc}.")
                        );
                    break;
                }
            };

            // If row length is odd and we are at the edge this is a root.
            if pos == row_len_acc + actual_row_len - 1 && actual_row_len % 2 == 1 {
                calculated_root_hashes.append(node);
                row_len_acc += row_len;
                row_len /= 2;
                actual_row_len /= 2;
                continue;
            };

            let parent_node = if (pos - row_len_acc) % 2 == 0 {
                // Right sibling can be both leaf/computed or proof.
                let right_sibling = if next_leaf_pos == pos + 1 {
                    let res = next_leaf;
                    let (a, b) = leaf_nodes.pop_front().unwrap_or((Bounded::<u64>::MAX, 0));
                    next_leaf_pos = a;
                    next_leaf = b;
                    res
                } else if next_computed_pos == pos + 1 {
                    let res = next_computed;
                    let (a, b) = computed_nodes.pop_front().unwrap_or((Bounded::<u64>::MAX, 0));
                    next_computed_pos = a;
                    next_computed = b;
                    res
                } else {
                    if sibling_nodes.is_empty() {
                        inner_result = Result::Err("Proof is empty.");
                        break;
                    };
                    sibling_nodes.pop_front().unwrap()
                };
                parent_hash(node, right_sibling)
            } else {
                // Left sibling always from proof.
                if let Option::Some(left_sibling) = sibling_nodes.pop_front() {
                    parent_hash(left_sibling, node)
                } else {
                    inner_result = Result::Err("Proof is empty.");
                    break;
                }
            };

            let parent_pos = row_len_acc + row_len + (pos - row_len_acc) / 2;

            if next_computed_pos == Bounded::<u64>::MAX {
                next_computed_pos = parent_pos;
                next_computed = parent_node;
            } else {
                computed_nodes.append((parent_pos, parent_node));
            }
        };

        if !sibling_nodes.is_empty() {
            return Result::Err("Proof should be empty");
        }

        if inner_result != Result::Ok((array![].span())) {
            inner_result
        } else {
            Result::Ok((calculated_root_hashes.span()))
        }
    }
}

/// PartialOrd implementation for tuple (u32, felt252).
impl PartialOrdTupleU64Felt252 of PartialOrd<(u64, felt252)> {
    fn lt(lhs: (u64, felt252), rhs: (u64, felt252)) -> bool {
        let (a, _) = lhs;
        let (b, _) = rhs;

        if a < b {
            true
        } else {
            false
        }
    }
}

