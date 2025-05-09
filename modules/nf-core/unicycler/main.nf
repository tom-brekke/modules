process UNICYCLER {
    tag "$meta.id"
    label 'process_high'

    conda "${moduleDir}/environment.yml"
    container "${ workflow.containerEngine == 'singularity' && !task.ext.singularity_pull_docker_container ?
        'https://community-cr-prod.seqera.io/docker/registry/v2/blobs/sha256/2b/2b9f404e2169ea74161d63d24f55d6339dc98c3745bf2442e425d5a673617fca/data' :
        'community.wave.seqera.io/library/unicycler:0.5.1--b9d21c454db1e56b' }"

    input:
    tuple val(meta), path(shortreads), path(longreads)

    output:
    tuple val(meta), path('*.scaffolds.fa.gz'), emit: scaffolds
    tuple val(meta), path('*.assembly.gfa.gz'), emit: gfa
    tuple val(meta), path('*.log')            , emit: log
    path  "versions.yml"                      , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def args = task.ext.args ?: ''
    def prefix = task.ext.prefix ?: "${meta.id}"
    def short_reads = shortreads ? ( meta.single_end ? "-s $shortreads" : "-1 ${shortreads[0]} -2 ${shortreads[1]}" ) : ""
    def long_reads  = longreads ? "-l $longreads" : ""
    """
    unicycler \\
        --threads $task.cpus \\
        $args \\
        $short_reads \\
        $long_reads \\
        --out ./

    mv assembly.fasta ${prefix}.scaffolds.fa
    gzip -n ${prefix}.scaffolds.fa
    mv assembly.gfa ${prefix}.assembly.gfa
    gzip -n ${prefix}.assembly.gfa
    mv unicycler.log ${prefix}.unicycler.log

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        unicycler: \$(echo \$(unicycler --version 2>&1) | sed 's/^.*Unicycler v//; s/ .*\$//')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """

    cat "" | gzip > ${prefix}.scaffolds.fa.gz
    cat "" | gzip >  ${prefix}.assembly.gfa.gz
    touch ${prefix}.unicycler.log

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        unicycler: \$(echo \$(unicycler --version 2>&1) | sed 's/^.*Unicycler v//; s/ .*\$//')
    END_VERSIONS
    """

}
