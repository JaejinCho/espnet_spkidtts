#!/bin/bash

# JJ: Edited from ../asrtts+spkid_sre_phonealign/run.asrttsspkid.sh (Note: there won't be ${dumpdir}/${cname}_combined or data/${cname}_combined for labeled corpora. They are processed separately in train and dev. Thus, only ${dumpdir}/${cname}_combined_{train,dev} & data/${cname}_combined_{train,dev} exist)

# Copyright 2019 Nagoya University (Takenori Yoshimura)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

. ./path.sh || exit 1;
. ./cmd.sh || exit 1;

# general configuration
backend=pytorch
stage=0
stop_stage=100
ngpu=1       # number of gpu in training
nj=64        # numebr of parallel jobs
dumpdir=dump # directory to dump full features
verbose=0    # verbose option (if set > 1, get more log)
seed=1       # random seed number
resume=""    # the snapshot path to resume (if set empty, no effect)
cuda_memsize=50

# feature extraction related (set by following /export/b18/jcho/espnet3/egs/libritts/tts_featext/run.FE.diffconfig.voxceleb1.sh)
fs=16000      # sampling frequency
fmax=""       # maximum frequency
fmin=""       # minimum frequency
n_mels=80     # number of mel basis
n_fft=512    # number of fft points (32ms) ***** JJ: maybe this leads to a poor result? (tacotron2 paper: 50ms, previous run.sh ~42ms)
n_shift=160   # number of shift points (10ms)
win_length="" # window length

# config files
train_config=conf/train_pytorch_forwardtacotron2+spkemb_2flstm512Nusecat_fullyunsync_shufflebatching_semi_multicorpora.yaml
decode_config=conf/decode.yaml

# decoding related
model=model.loss.best
n_average=1 # if > 0, the model averaged with n_average ckpts will be used instead of model.loss.best
griffin_lim_iters=64  # the number of iterations of Griffin-Lim

# Speaker id related
spkloss_weight=0.03

# Set this to somewhere where you want to put your data, or where
# someone else has already put it. You'll want to change this
# if you're not on the CLSP grid.
datadir=/export/a15/vpanayotov/data

# base url for downloads.
data_url=www.openslr.org/resources/60

# exp tag
tag="" # tag for managing experiments.

. utils/parse_options.sh || exit 1;

# Set bash to 'debug' mode, it will exit on :
# -e 'error', -u 'undefined variable', -o ... 'error in pipeline', -x 'print commands',
set -e
set -u
set -o pipefail

feat_dir=/export/b18/jcho/espnet3/egs/libritts/tts_featext
sre20_dir=../asrtts+spkid_sre_phonealign/
trans_dir=/export/b11/jcho/kaldi_20190316/egs/babel/masr_grapheme/exp/chain/tdnn1h_d_sp/
train_set=sre20Nkaldiaug_train

corpora_list_lab="fisher_spa sre16_eval_tr60_tgl sre16_eval_tr60_yue sre16_train_dev_ceb sre18_cmn2_train_lab sre_tel swbd voxcelebcat_tel sre16_train_dev_cmn"
corpora_list_nolab="babel_amharic babel_assamese babel_bengali babel_cantonese babel_cebuano babel_dholuo babel_georgian babel_guarani babel_haitian babel_igbo babel_javanese babel_kazakh babel_kurmanji babel_lao babel_lithuanian babel_mongolian babel_pashto babel_swahili babel_tagalog babel_tamil babel_telugu babel_tokpisin babel_turkish babel_vietnamese babel_zulu"


if [ ${stage} -le 0 ] && [ ${stop_stage} -ge 0 ]; then
    echo "stage 0: Data preparation. Assuming stage 0 in ../asrtts+spkid_sre_phonealign/run.asrttsspkid.sh is already run (it is the data prep. stage for the recipe)"
    if [ ! -d data ]; then
        mkdir -p data
    fi
    # lab data
    for cname in ${corpora_list_lab}; do
        # oriamt stands for original amount, which means the amount of utterances in the original (before augmentation) corpus
        divide_into_trainNdev.py ${sre_dir}/data/${cname}/${cname}_dev.uttlist ${feat_dir}/data/${cname}_aug_oriamt/utt2spk # this will generate ${feat_dir}/data/${cname}_aug_oriamt/utt2spk.{train,dev} 
        for subset in train dev; do
            # original data fixed
            ln -s ${sre_dir}/data/${cname}_${subset} data/${cname}_${subset}
            # aug_oriamt data to be fixed
            cp ${feat_dir}/data/${cname}_aug_oriamt data/${cname}_aug_oriamt_${subset}
            mv data/${cname}_aug_oriamt_${subset}/utt2spk.${subset} data/${cname}_aug_oriamt_${subset}/utt2spk
            utils/fix_data_dir.sh data/${cname}_aug_oriamt_${subset}
            # Process a text & utt2spklab files
            map_utt2textNspklab.py ${sre_dir}/data/${cname}/ data/${cname}_aug_oriamt_${subset}/ 
            
            utils/combine_data.sh data/${cname}_combined_${subset} data/${cname}_aug_oriamt_${subset} data/${cname}_${subset}
            utils/fix_data_dir.sh data/${cname}_combined_${subset}
        done
    done
    # nolab data
    for cname in ${corpora_list_nolab}; do
        # original data
        ln -s ${sre_dir}/data/${cname} data/${cname}
        # aug_oriamt data
        cp -r ${feat_dir}/data/${cname}_aug_oriamt data/${cname}_aug_oriamt
        # Process a text file
         map_utt2text.py ${sre_dir}/data/${cname}/ data/${cname}_aug_oriamt/

        utils/combine_data.sh data/${cname}_combined data/${cname}_aug_oriamt data/${cname}
        utils/fix_data_dir.sh data/${cname}_combined
    done
fi

for cname in ${corpora_list_lab} ${corpora_list_nolab} ;do
    if [[ "$cname" == *"babel"* ]]; then
        mkdir -p ${dumpdir}/${cname}_aug_oriamt_nolab # assuming b4aug corpora are already dumped
        mkdir -p ${dumpdir}/${cname}_combined_nolab
    else
        for subset in train dev; do
            mkdir -p ${dumpdir}/${cname}_aug_oriamt_${subset} # assuming b4aug corpora are already dumped
            mkdir -p ${dumpdir}/${cname}_combined_${subset}
        done
    fi
done


if [ ${stage} -le 1 ] && [ ${stop_stage} -ge 1 ]; then
    ### Task dependent. You have to design training and dev name by yourself.
    ### But you can utilize Kaldi recipes in most cases
    echo "stage 1: Feature Generation (dump using apply-cmvn-sliding). Assuming this normalization is done already for b4aug corpora in ../asrtts+spkid_sre_phonealign/run.asrttsspkid.sh already"
    pids=() # initialize pids
    for cname in `echo ${corpora_list_lab} ${corpora_list_nolab}`;do
    (
        if [[ "$cname" == *"babel"* ]]; then
            echo "NOLAB: $cname"
            dump_cmvnsliding.sh --cmd "$train_cmd" --nj ${nj} --do_delta false \
                data/${cname}_aug_oriamt/feats.scp exp/dump_feats/${cname}_aug_oriamt_nolab ${dumpdir}/${cname}_aug_oriamt_nolab
            cat ${dumpdir}/${cname}_nolab/feats.scp ${dumpdir}/${cname}_aug_oriamt_nolab/feats.scp > ${dumpdir}/${cname}_combined_nolab/feats.scp
            cat ${dumpdir}/${cname}_nolab/utt2num_frames ${dumpdir}/${cname}_aug_oriamt_nolab/utt2num_frames > ${dumpdir}/${cname}_combined_nolab/utt2num_frames
        else
            echo "LAB: $cname"
            for subset in train dev; do
                dump_cmvnsliding.sh --cmd "$train_cmd" --nj ${nj} --do_delta false \
                    data/${cname}_aug_oriamt_${subset}/feats.scp exp/dump_feats/${cname}_aug_oriamt_${subset} ${dumpdir}/${cname}_aug_oriamt_${subset}
                cat ${dumpdir}/${cname}_${subset}/feats.scp ${dumpdir}/${cname}_aug_oriamt_${subset}/feats.scp > ${dumpdir}/${cname}_combined_${subset}/feats.scp
                cat ${dumpdir}/${cname}_${subset}/utt2num_frames ${dumpdir}/${cname}_aug_oriamt_${subset}/utt2num_frames > ${dumpdir}/${cname}_combined_${subset}/utt2num_frames
            done
        fi
    ) &
    pids+=($!) # store background pids
    done
    i=0; for pid in "${pids[@]}"; do wait ${pid} || ((i++)); done
    [ ${i} -gt 0 ] && echo "$0: ${i} background jobs are failed." && false
    echo "Finished."
fi

dict=data/lang_1char/${train_set}_units.txt
echo "dictionary: ${dict}"
if [ ${stage} -le 2 ] && [ ${stop_stage} -ge 2 ]; then
    ### Task dependent. You have to check non-linguistic symbols used in the corpus.
    echo "stage 2: Dictionary and Json Data Preparation"
    mkdir -p data/lang_1char/
    cp ${trans_dir}/phones.txt ${dict}
    sed -e '1 s:<eps> 0:<unk> 0:' ${dict} | awk -F' ' '{$2=$2+1;print}' OFS=' ' > .tmpdict && mv .tmpdict ${dict}
    wc -l ${dict}

    # make json labels
    pids=()
    for cname in ${corpora_list_lab} ${corpora_list_nolab}; do
    (
        if [[ "$cname" == *"babel"* ]]; then
            echo "NOLAB: $cname"
            qsub -wd /export/b18/jcho/espnet3/egs/libritts/asrtts+spkid_sreNkaldiaug_phonealign -o log/data2json_kaldiali.qsub.${cname}_combined_nolab.log -e log/data2json_kaldiali.qsub.${cname}_combined_nolab.log data2json_kaldiali.qsub.sh ${dumpdir} ${cname}_combined_nolab ${dict}
        else
            echo "LAB: $cname"
            for subset in train dev; do
                qsub -wd /export/b18/jcho/espnet3/egs/libritts/asrtts+spkid_sreNkaldiaug_phonealign -o log/data2json_kaldiali.qsub.${cname}_combined_${subset}.log -e log/data2json_kaldiali.qsub.${cname}_combined_${subset}.log data2json_kaldiali.qsub.sh ${dumpdir} ${cname}_combined_${subset} ${dict}
            done
        fi
    ) &
    pids+=($!)
    done
    i=0; for pid in "${pids[@]}"; do wait ${pid} || ((i++)); done
    [ ${i} -gt 0 ] && echo "$0: ${i} background jobs are failed." && false
    echo "Finished."

    # json prep. for speaker id module
    pids=()
    for cname in ${corpora_list_lab} ${corpora_list_nolab};do
    (
        if [[ "$cname" == *"babel"* ]]; then
            echo "NOLAB: $cname"
            awk '{print $1, -1}' ./data/${cname}_combined/utt2spk > ./data/${cname}_combined/utt2spklab
            qsub -wd /export/b18/jcho/espnet3/egs/libritts/asrtts+spkid_sreNkaldiaug_phonealign -o log/update_json_general.qsub.${cname}_combined_nolab.log -e log/update_json_general.qsub.${cname}_combined_nolab.log local/update_json_general.sh --loc output --k spklab ${dumpdir}/${cname}_combined_nolab/data.json ./data/${cname}_combined/utt2spklab
        else
            echo "LAB: $cname"
            for subset in train dev; do
                qsub -wd /export/b18/jcho/espnet3/egs/libritts/asrtts+spkid_sreNkaldiaug_phonealign -o log/update_json_general.qsub.${cname}_combined_${subset}.log -e log/update_json_general.qsub.${cname}_combined_${subset}.log local/update_json_general.sh --loc output --k spklab ${dumpdir}/${cname}_combined_${subset}/data.json ./data/${cname}_combined_${subset}/utt2spklab
            done
        fi
    ) &
    pids+=($!)
    done
    i=0; for pid in "${pids[@]}"; do wait ${pid} || ((i++)); done
    [ ${i} -gt 0 ] && echo "$0: ${i} background jobs are failed." && false
    echo "Finished."
fi

num_spk=0
for cname in ${corpora_list_lab} ${corpora_list_nolab}; do
    if [[ "$cname" != *"babel"* ]]; then
        #temp_num=$(wc -l data/${cname}_combined/spk2utt | awk '{print $1}')
        temp_num=$(cat data/${cname}_combined_{train,dev}/spk2utt | awk '{print $1}' | sort -u | wc -l) # no data/${cname}_combined dirs exist for lab corpora
        num_spk=$((num_spk+temp_num))
    fi
done
echo "The number of speakers for spkid training: ${num_spk}. 15072 for sre20 or sre20Nkaldiaug recipe"

if [ -z ${tag} ]; then
    expname=${train_set}_$(basename ${train_config%.*})
else
    expname=${train_set}_$(basename ${train_config%.*})_${tag}
fi

expname=${expname}_spkloss_weight${spkloss_weight}_fullyunsync

expdir=exp/${expname}
mkdir -p ${expdir}
if [ ${stage} -le 4 ] && [ ${stop_stage} -ge 4 ]; then
    echo "stage 4: Text-to-speech model training"
    # build tr_json* and dt_json
    tr_json_nolab=""
    tr_json=""
    dt_json=""
    for cname in ${corpora_list_lab} ${corpora_list_nolab}; do
        if [[ "$cname" == *"babel"* ]]; then
            tr_json_nolab+="${dumpdir}/${cname}_combined_nolab/data.json "
        else
            echo "LAB: $cname"
            tr_json+="${dumpdir}/${cname}_combined_train/data.json "
            dt_json+="${dumpdir}/${cname}_combined_dev/data.json "
        fi
    done

    # actual run
    if [ ${cuda_memsize} == 5 ]; then
        cuda_cmd_train=${cuda_cmd_mem5G}
    elif [ ${cuda_memsize} == 10 ];then
        cuda_cmd_train=${cuda_cmd_mem10G}
    elif [ ${cuda_memsize} == 20 ];then
        cuda_cmd_train=${cuda_cmd_mem20G}
    elif [ ${cuda_memsize} == 50 ];then
        cuda_cmd_train=${cuda_cmd_mem50G}
    else
        cuda_cmd_train=${cuda_cmd}
    fi
    echo "cuda_cmd_train: ${cuda_cmd_train}"
    ${cuda_cmd_train} --gpu ${ngpu} ${expdir}/train.log \
        tts_train_speakerid_semi_multicorpora.py \
           --num-spk ${num_spk} \
           --train-spkid-extractor True \
           --train-spk-embed-dim 400 \
           --spkloss-weight ${spkloss_weight} \
           --backend ${backend} \
           --ngpu ${ngpu} \
           --outdir ${expdir}/results \
           --tensorboard-dir tensorboard/${expname} \
           --verbose ${verbose} \
           --seed ${seed} \
           --resume ${resume} \
           --train-json-nolab "${tr_json_nolab}" \
           --train-json "${tr_json}" \
           --valid-json "${dt_json}" \
           --config ${train_config}
fi