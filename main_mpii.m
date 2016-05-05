% Train and evaluate a model on the MPII dataset

startup;
conf = get_conf_mpii;
[train_dataset, val_dataset, test_seqs] = get_mpii_cooking(...
    conf.dataset_dir, conf.cache_dir, conf.pair_mean_dist_thresh, ...
    conf.subposes, conf.cnn.step, conf.template_scale, conf.trans_spec);
% Check that conf.num_joints is consistent with data
sizes_okay = @(ds) all(cellfun(@length, {ds.data.joint_locs}) == conf.num_joints);
assert(sizes_okay(train_dataset) && sizes_okay(val_dataset));
% INRIAPerson data is only used for training the graphical model; I used
% person-free crops of MPII cooking to train the CNN to recognise
% background.
neg_dataset = get_inria_person(conf.dataset_dir, conf.cache_dir);

fprintf('Writing validation positives\n');
val_patch_dir = fullfile(conf.cache_dir, 'val-patches-mpii');
write_dset(val_dataset, val_patch_dir, conf.num_val_hdf5s, ...
    conf.cnn.window, conf.cnn.step, conf.subposes, conf.left_parts, ...
    conf.right_parts, conf.val_aug, conf.val_chunksz);

fprintf('Writing training positives\n');
train_patch_dir = fullfile(conf.cache_dir, 'train-patches-mpii');
write_dset(train_dataset, train_patch_dir, conf.num_hdf5s, ...
    conf.cnn.window, conf.cnn.step, conf.subposes, conf.left_parts, ...
    conf.right_parts, conf.aug, conf.train_chunksz);

% Cluster before writing negatives so that we can use the clusters to pick
% challenging negatives (ones with ineffable subposes)
fprintf('Writing cluster information\n');
biposelets = cluster_h5s(conf.biposelet_classes, conf.subposes, ...
    train_patch_dir, val_patch_dir, conf.cache_dir);

fprintf('Writing validation negatives\n');
write_negatives(val_dataset, biposelets, val_patch_dir, ...
    conf.cnn.window, conf.val_aug, conf.val_chunksz, conf.subposes);

fprintf('Writing training negatives\n');
write_negatives(train_dataset, biposelets, train_patch_dir, ...
    conf.cnn.window, conf.aug, conf.train_chunksz, conf.subposes);


fprintf('Calculating mean pixel\n');
store_mean_pixel(train_patch_dir, conf.cache_dir);

fprintf('Training CNN\n');
cnn_train(conf.cnn, conf.cache_dir);

fprintf('Computing ideal poselet displacements\n');
subpose_disps = save_centroid_pairwise_means(...
    conf.cache_dir, conf.subpose_pa, conf.shared_parts);

fprintf('Caching flow for positive validation pairs\n');
cache_all_flow(val_dataset, conf.cache_dir);
fprintf('Caching flow for negative pairs\n');
cache_all_flow(neg_dataset, conf.cache_dir);

fprintf('Training graphical model\n');
ssvm_model = train_model(conf, val_dataset, neg_dataset, subpose_disps);

fprintf('Running bipose detections on validation set\n');
pair_dets = get_pair_dets(conf.cache_dir, test_seqs, ssvm_model, ...
    biposelets, conf.subposes, conf.num_joints, conf.num_dets);

fprintf('Stitching detections into sequence\n');
pose_dets = stitch_all_seqs(pair_dets, conf.stitch_weights, ...
    conf.valid_parts, conf.cache_dir);
pose_gts = get_gts(test_seqs);

fprintf('Calculating statistics\n');
flat_dets = cat(2, pose_dets{:});
flat_gts = cat(2, pose_gts{:});
pck_thresholds = conf.pck_thresholds;
all_pcks = pck(flat_dets, flat_gts, pck_thresholds); %#ok<SNASGU>
limbs = conf.limbs;
all_pcps = pcp(flat_dets, flat_gts, {limbs.indices}); %#ok<SNASGU>
save(fullfile(conf.cache_dir, 'final-stats.mat'), 'all_pcks', ...
    'all_pcps', 'pck_thresholds', 'limbs');

fprintf('Done!\n');
