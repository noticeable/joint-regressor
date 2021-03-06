function [score, Ix, Iy, Im] = passmsg(child, parent, scale)
% Pass a message from child component to parent component, returning four
% H*W*K matrices. In each matrix, the (h, w, k)-th entry corresponds to a
% parent of type k at location (h, w). The matrices can be interpreted as
% follows:
% - score gives score of best subpose in which parent has specified
%   location and type
% - Ix gives the x location of the current child in the best subpose that
%   has parent in specified configuration
% - Iy is the same but for child y location
% - Im is the same but for child type
height = size(parent.score, 1);
width = size(parent.score, 2);
% Number of parent and child types, respectively
parent_K = size(parent.score, 3);
child_K = size(child.score, 3);
assert(child_K == parent_K);

[score0, Ix0, Iy0] = deal(zeros(height, width, parent_K, child_K));
parfor parent_type = 1:parent_K
    for child_type = 1:child_K
        fixed_score_map = double(child.score(:, :, child_type)); %#ok<PFBNS>
        % this is child_center - parent_center, IIRC
        mean_disp = child.subpose_disps{child_type}{parent_type} / scale;
        assert(isvector(mean_disp) && length(mean_disp) == 2);
        [score0(:, :, parent_type, child_type), Ix0(:, :, parent_type, child_type), ...
            Iy0(:, :, parent_type, child_type)] = shiftdt(...
                fixed_score_map, child.gauw, mean_disp, int32([width, height]));
        
        % If there was a prior-of-deformation (like the image evidence in
        % Chen & Yuille's model), then I would add it in here.
    end
end
[score, Im] = max(score0, [], 4);
assert(ndims(Im) < 4 && size(Im, 3) == parent_K);
[Ix, Iy] = deal(zeros(height, width, parent_K));
for row = 1:height
    for col = 1:width
        for ptype = 1:parent_K
            ctype = Im(row, col, ptype);
            assert(isscalar(ctype) && 1 <= ctype && ctype <= child_K);
            Ix(row, col, ptype) = Ix0(row, col, ptype, ctype);
            Iy(row, col, ptype) = Iy0(row, col, ptype, ctype);
        end
    end
end
% "score" is a message that will be added to the parent's total score in
% detect.m. Hence, we need it to be the right size.
% This assertion uses destructuring-followed-by-comparison because
% otherwise it fails for parent_K == 1 (where the last dimension of score's
% size disappears).
[score_h, score_w, score_K] = size(score);
assert(all([score_h, score_w, score_K] == [height width parent_K]));
