#!/bin/bash
#BSUB -P CMB139
#BSUB -J pt2pt_comp_MV2X 
#BSUB -W 80
#BSUB -nnodes 2
#BSUB -o pt2pt_comp_MV2X.log

module load cuda/9.2.148

# TODO: build your own builds and put the path of MPI libraries to be compared
SMPI_HOME=/autofs/nccs-svm1_sw/summit/.swci/1-compute/opt/spack/20180914/linux-rhel7-ppc64le/xl-16.1.1-3/spectrum-mpi-10.3.0.0-20190419-q75ow22tialepxlgxcs7esrptqwoheij
OLD_MPI_HOME=$SMPI_HOME
MV2X_HOME=/ccs/home/kshafie/mvapich_builds/master-x/install
GDR_HOME=
MPI_HOME=$MV2X_HOME
OMB_PATH=/ccs/home/kshafie/benchmarks/osu-micro-benchmarks

do_comp=1 

# TODO: submit this script using following command
# bsub ./simpleRegression_pt2pt_lassen.bash
# TODO: or allocate node(s) using following command and run this script
# bsub -nnodes 2 -P CMB139 -W 30 -Ip bash

build_omb=0
if [ $build_omb -eq 1 ]
then
    cd $OMB_PATH
    autoreconf -vif
    ./configure --prefix=$OMB_PATH/MV2X-install CC=$MPI_HOME/bin/mpicc CXX=$MPI_HOME/bin/mpicxx #\
#        --enable-cuda --with-cuda-include=/sw/summit/cuda/9.2.148/include --with-cuda-libpath=/sw/summit/cuda/9.2.148/lib64
    make clean && make install
    if [ $do_comp -eq 1  ]; then
        autoreconf -vif
        ./configure --prefix=$OMB_PATH/Spec-install CC=$OLD_MPI_HOME/bin/mpicc CXX=$OLD_MPI_HOME/bin/mpicxx #\
#            --enable-cuda --with-cuda-include=/sw/summit/cuda/9.2.148/include --with-cuda-libpath=/sw/summit/cuda/9.2.148/lib64
        make clean && make install
    fi
    cd -
fi

n=2
### generate desired hostfile, block distribution
# TODO: for intra-node test, use 'ppn=2', otherwise using 'ppn=1'
for ppn in 1 2
do

HFILE=./hf-$LSB_JOBID
jsrun -r $ppn -d packed hostname | sort > $HFILE
cat $HFILE

np=`expr $ppn \* $n`

# TODO: modfiy max. message size to be tested
max_msg=268435456
# TODO: test D-D or H-H
buf_opt="H H"

newlogfile=./new-pt2pt
oldlogfile=./old-pt2pt

mpi_flags_default= "MV2_USE_RDMA_CM=0"
#mpi_flags_default="MV2_USE_GPUDIRECT_LOOPBACK=0 MV2_USE_CUDA=1 MV2_USE_GPUDIRECT_RDMA=1 MV2_USE_GPUDIRECT_GDRCOPY=0 MV2_USE_RDMA_CM=0 MV2_INTER_BCAST_TUNING=1 MV2_CUDA_ENABLE_MANAGED=1 MV2_CUDA_MANAGED_IPC=1"
export $mpi_flags_default

coll_tests=( "bcast" )
pt2pt_tests=("latency" "bw" "bibw")

for i in `seq 1 3`
do
    ### pt2pt
    for tname in "${pt2pt_tests[@]}"
    do
        echo "Runing osu_${tname}...Iteration $i"
        $MPI_HOME/bin/mpirun_rsh -np 2 --hostfile $HFILE $mpi_flags_default $OMB_PATH/MV2X-install/libexec/osu-micro-benchmarks/get_local_rank $OMB_PATH/MV2X-install/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_${tname} -m 1:$max_msg -x 50 $buf_opt >> $newlogfile-${tname}
        
        if [ $do_comp -eq 1 ]; then
            ### SpectrumMPI
            $OLD_MPI_HOME/bin/mpirun -np 2 -N $ppn --hostfile $HFILE $OMB_PATH/Spec-install/libexec/osu-micro-benchmarks/get_local_rank $OMB_PATH/Spec-install/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_${tname} -m 1:$max_msg -x 50 $buf_opt >> $oldlogfile-${tname}
        fi
    done
done


### SpectrumMPI
#mpirun -gpu -np 2 -npernode 1 --hostfile $HFILE hostname
#mpirun -gpu -np 2 --map-by node --hostfile $HFILE -x PAMI_IBV_ADAPTER_AFFINITY=0 /g/g91/chu30/mv2-src/osu-micro-benchmarks/omb-install-spectrum/libexec/osu-micro-benchmarks/mpi/pt2pt/osu_bw D D
echo "BEGIN{}
{
    msg = \$1
    lat = \$2
    
    avg_lat[msg] += lat
    cnt_lat[msg] ++
}
END{
    for(m=1 ; m<=$max_msg ; m*=2)
        printf(\"%d\\t%f\\n\", m, avg_lat[m]/cnt_lat[m])
}
" > avg-latency.awk

echo "BEGIN{}
{
    msg = \$1
    bw = \$2

    if (msg != \"#\" && bw > 0) {
        avg_bw[msg] += (1/bw)
        cnt_bw[msg] ++
    }
}
END{
    for(m=1 ; m<=$max_msg ; m*=2) {
        printf(\"%d\\t%f\\n\", m, cnt_bw[m]/avg_bw[m])
    }
}
" > avg-bw.awk
cp avg-bw.awk avg-bibw.awk

echo "BEGIN{
    printf (\"Size\\t\\tOld\\t\\tNEW\\t\\tDiff\\n\")
}
{
    msg = \$1
    old = \$2
    new = \$4
    if (tn == \"bw\" || tn == \"bibw\")
        diff = (new-old)/new
    else
        diff = (old-new)/old

    if (diff < -0.1)
        printf (\"%d\\t\\t%.3f\\t\\t%.3f\\t\\t%.3f\\n\", msg, old, new, diff)
    else
        printf (\"%d\\t\\t%.3f\\t\\t%.3f\\n\", msg, old, new)
}
END{
}
" > avg-diff.awk


if [ $ppn -eq 1  ]
then
    echo "===== Pt2pt, Inter-node ====="
else
    echo "===== Pt2pt, Intra-node ====="
fi
for tname in "${pt2pt_tests[@]}"
do
    ### get average
    awk -f avg-${tname}.awk $newlogfile-${tname} > $newlogfile-${tname}.avg
    echo "--- ${tname} ---"
    if [ $do_comp -eq 1 ]
    then
        awk -f avg-${tname}.awk $oldlogfile-${tname} > $oldlogfile-${tname}.avg
        ### paste both numbers together
        paste $oldlogfile-${tname}.avg $newlogfile-${tname}.avg  > mix.${tname}.avg
        ### calculate diff and report where we have performance degradation > 10%
        awk -v tn="${tname}" -f avg-diff.awk mix.${tname}.avg
    else
        ### not comparing, just report it
        cat $newlogfile-${tname}.avg
    fi
done

#rm $HFILE avg-*.awk *.avg
#rm -f $newlogfile-* $oldlogfile-*
done

