function write_dset(dataset, patch_dir, num_hdf5s, ...
    cnn_window, subposes, left_parts, right_parts, aug, chunksz)
%WRITE_DSET Write out a data set (e.g. pairs from the train set or pairs
%from the test set).

% opts will be used later for writing to hdf5s
opts.chunksz = chunksz;
confirm_path = fullfile(patch_dir, '.written');

if ~exist(patch_dir, 'dir')
    mkdir(patch_dir);
else
    if exist(confirm_path, 'file')
        % Don't re-write
        fprintf('Patches in %s already exist; skipping\n', patch_dir);
        return
    end
end

% I'm using a nested for/parfor like Anoop suggested to parallelise
% augmentation calculation. This lets me write to a single file in without
% making everything sequential or resorting to locking hacks. The implicit
% barrier is annoying, but shouldn't matter too much given that
% augmentations are the same each time.
pool = gcp;
batch_size = pool.NumWorkers;

rem_pairs_path = fullfile(patch_dir, 'rem_pairs.mat');

try
    % XXX: This is suboptimal. Should have a unique name for pair cache.
    loaded = load(rem_pairs_path);
    rem_pairs = loaded.rem_pairs_trimmed;
    fprintf('Loaded remaining pairs from cache\n');
    fprintf('%i pairs left\n', length(rem_pairs));
catch ex
    if ~any(strcmp(ex.identifier, {'MATLAB:load:couldNotReadFile', 'MATLAB:nonExistentField'}))
        ex.rethrow();
    end
    rem_pairs = dataset.pairs;
    fprintf('No cached pairs; starting anew\n');
end

if isempty(rem_pairs)
    fprintf('No pairs to write; exiting');
    return;
end

assert(isstruct(rem_pairs) && isvector(rem_pairs));

for start_index = 1:batch_size:length(rem_pairs)
    true_batch_size = min(batch_size, length(rem_pairs) - start_index + 1);
    results = cell([1 true_batch_size]);
    % Calculate in parallel
    fprintf('Augmenting samples %i to %i\n', ...
        start_index, start_index + true_batch_size - 1);
    ds_data = dataset.data;
    parfor result_index=1:true_batch_size
        mpii_index = start_index + result_index - 1;
        pair = rem_pairs(mpii_index); %#ok<PFBNS>
        fst = ds_data(pair.fst); %#ok<PFBNS>
        snd = ds_data(pair.snd);
        
        stack_start = tic;
        results{result_index} = get_stacks(...
            fst, snd, pair.scale, subposes, left_parts, right_parts, ...
            cnn_window, aug);
        stack_time = toc(stack_start);
        fprintf('get_stack() took %fs\n', stack_time);
    end
    
    fprintf('Got %i stacks\n', length(results));
    
    % Write sequentially
    for i=1:length(results)
        write_start = tic;
        stacks = results{i};
        for stack_num=1:length(stacks)
            % Get stack and labels; we don't add in dummy dimensions
            % because apparently Matlab can't tell the difference between a
            % j*k*l*1*1*1*1... matrix and a j*k*l matrix.
            stack = stacks(stack_num).stack;
            
            % Choose a file, regardless of whether it exists
            h5_idx = randi(num_hdf5s);
            filename = fullfile(patch_dir, sprintf('samples-%06i.h5', h5_idx));
            
            % Write!
            assert(size(stack, 3) == 8, 'you need to rewrite this to handle flow');
            % We split the flow out from the images so that we can write the
            % images as uint8s
            stack_flow = single(stack(:, :, 7:8, :));
            stack_im = stack(:, :, 1:6, :);
            stack_im_bytes = uint8(stack_im * 255);
            % 1-of-K array of class labels. Ends up having dimension K*N,
            % where N is the unmber of samples and K is the number of
            % classes (i.e. number of subposes plus one for background
            % class).
            class_labels = one_of_k(stacks(stack_num).subpose_num + 1, ...
                length(subposes) + 1)';
            joint_args = {};
            for subpose_idx=1:length(subposes)
                name = subposes(subpose_idx).name;
                joint_args{length(joint_args)+1} = sprintf('/%s', name); %#ok<AGROW>
                if subpose_idx ~= stacks(stack_num).subpose_num;
                    num_values = 4 * length(subposes(subpose_idx).subpose);
                    subpose_data = zeros([num_values, 1]);
                else
                    subpose_data = stacks(stack_num).joint_labels;
                end
                joint_args{length(joint_args)+1} = single(subpose_data); %#ok<AGROW>
                assert(size(subpose_data, 2) == 1);
            end
            assert(any(joint_args{2*subpose_idx-1}), ...
                'Joint labels for current subpose are all zero (?!)');
            store3hdf6(filename, opts, '/flow', stack_flow, ...
                '/images', stack_im_bytes, ...
                '/class', uint8(class_labels), ...
                joint_args{:});
        end
        
        % Write out the remaining pairs for resumable training
        rem_pairs_trimmed = rem_pairs(start_index+true_batch_size:end); %#ok
        save(rem_pairs_path, 'rem_pairs_trimmed');
        
        write_time = toc(write_start);
        fprintf('Writing %d examples took %fs\n', length(stacks), write_time);
    end
end

fid = fopen(confirm_path, 'w');
fprintf(fid, '');
fclose(fid);
end
