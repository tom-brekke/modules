//
// Perform differential analysis
//

include { LIMMA_DIFFERENTIAL                  } from '../../../modules/nf-core/limma/differential/main'
include { LIMMA_DIFFERENTIAL as LIMMA_NORM    } from '../../../modules/nf-core/limma/differential/main'
include { DESEQ2_DIFFERENTIAL                 } from '../../../modules/nf-core/deseq2/differential/main'
include { DESEQ2_DIFFERENTIAL as DESEQ2_NORM  } from '../../../modules/nf-core/deseq2/differential/main'
include { PROPR_PROPD                         } from '../../../modules/nf-core/propr/propd/main'
include { CUSTOM_FILTERDIFFERENTIALTABLE      } from '../../../modules/nf-core/custom/filterdifferentialtable/main'
include { VARIANCEPARTITION_DREAM             } from '../../../modules/nf-core/variancepartition/dream/main'

// Combine meta maps, including merging non-identical values of shared keys (e.g. 'id')
def mergeMaps(meta, meta2){
    (meta + meta2).collectEntries { k, v ->
        meta[k] && meta[k] != v ? [k, "${meta[k]}_${v}"] : [k, v]
    }
}

workflow ABUNDANCE_DIFFERENTIAL_FILTER {
    take:
    // Things we may need to iterate
    ch_input                 // [[meta_input], counts, analysis method, fc_threshold, stat_threshold]

    // Workflow-wide things, we don't need to iterate
    ch_samplesheet           // [ meta_exp, samplesheet ]
    ch_transcript_lengths    // [ meta_exp, transcript_lengths]
    ch_control_features      // [meta_exp, control_features]
    ch_contrasts             // [[ meta_contrast, contrast_variable, reference, target, formula, comparison ]]

    main:

    ch_versions = Channel.empty()

    // Set up how the channels crossed below will be used to generate channels for processing
    def criteria = multiMapCriteria { meta_input, abundance, analysis_method, fc_threshold, stat_threshold, meta_exp, samplesheet, meta_contrasts, variable, reference, target, formula, comparison ->
        def meta_for_diff = mergeMaps(meta_contrasts, meta_input) + [ 'method_differential': analysis_method ]
        def meta_input_new = meta_input + [ 'method_differential': analysis_method ]
        samples_and_matrix:
            [ meta_input_new, samplesheet, abundance ]
        contrasts_for_diff:
            [ meta_for_diff, variable, reference, target ]
        contrasts_for_diff_with_formula:
            [ meta_for_diff, variable, reference, target, formula, comparison ]
        filter_params:
            [ meta_for_diff, [ 'fc_threshold': fc_threshold, 'stat_threshold': stat_threshold ]]
        contrasts_for_norm:
            [ meta_input_new, variable, reference, target ]
    }

    // For DIFFERENTIAL modules we need to cross the things we're iterating so we
    // run differential analysis for every combination of matrix and contrast
    inputs = ch_input
        .combine(ch_samplesheet)
        .combine(ch_contrasts)
        .multiMap(criteria)

    // We only need a normalised matrix from one contrast. The reason we don't
    // simply use the first output from DIFFERENTIAL modules is that depending
    // on the contrast setting etc, these modules may subset matrices, hence
    // not returning the full normalized matrix as NORM modules would do.
    norm_inputs = ch_input
        .combine(ch_samplesheet)
        .combine(ch_contrasts.first()) // Just taking the first contrast
        .multiMap(criteria)

    // ----------------------------------------------------
    // Run Limma
    // ----------------------------------------------------

    // NOTE that we run LIMMA_NORM just once to generate a normalised matrix.
    // As explained above, this is done to avoid obtaining a subset matrix
    // from LIMMA_DIFFERENTIAL.

    // Also NOTE that LIMMA_DIFFERENTIAL don't use the normalized matrix from
    // LIMMA_NORM directly. It internally runs normalization + DE analysis.

    LIMMA_NORM(
        norm_inputs.contrasts_for_norm.filter{it[0].method_differential == 'limma'},
        norm_inputs.samples_and_matrix.filter{it[0].method_differential == 'limma'}
    )

    ch_versions = ch_versions.mix(LIMMA_NORM.out.versions.first())

    LIMMA_DIFFERENTIAL(
        inputs.contrasts_for_diff.filter{ it[0].method_differential == 'limma' },
        inputs.samples_and_matrix.filter{ it[0].method_differential == 'limma' }
    )

    ch_versions = ch_versions.mix(LIMMA_DIFFERENTIAL.out.versions.first())

    // ----------------------------------------------------
    // Run DESeq2
    // ----------------------------------------------------

    // NOTE that we run DESEQ2_NORM just once to generate a normalised matrix.
    // As explained above, this is done to avoid obtaining a subset matrix
    // from DESEQ2_DIFFERENTIAL.

    // Also NOTE that DESEQ2_DIFFERENTIAL don't use the normalized matrix from
    // DESEQ2_NORM directly. It internally runs normalization + DE analysis.

    DESEQ2_NORM(
        norm_inputs.contrasts_for_norm.filter{it[0].method_differential == 'deseq2'},
        norm_inputs.samples_and_matrix.filter{it[0].method_differential == 'deseq2'},
        ch_control_features.first(),
        ch_transcript_lengths.first()
    )

    ch_versions = ch_versions.mix(DESEQ2_NORM.out.versions.first())

    DESEQ2_DIFFERENTIAL(
        inputs.contrasts_for_diff.filter{it[0].method_differential == 'deseq2'},
        inputs.samples_and_matrix.filter{it[0].method_differential == 'deseq2'},
        ch_control_features.first(),
        ch_transcript_lengths.first()
    )

    ch_versions = ch_versions.mix(DESEQ2_DIFFERENTIAL.out.versions.first())

    // ----------------------------------------------------
    // Run propd
    // ----------------------------------------------------

    // NOTE that this method don't rely on normalization, hence it does
    // not produce a normalized matrix.

    PROPR_PROPD(
        inputs.contrasts_for_diff.filter{it[0].method_differential == 'propd'},
        inputs.samples_and_matrix.filter { it[0].method_differential == 'propd' }
    )

    ch_versions = ch_versions.mix(PROPR_PROPD.out.versions.first())

    // ----------------------------------------------------
    // Run DREAM
    // ----------------------------------------------------

    // DREAM only runs with formula
    dream_inputs = inputs.contrasts_for_diff_with_formula
        .filter { meta, _variable, _reference, _target, formula, _comparison ->
            meta.method_differential == 'dream' && formula != null
        }

    VARIANCEPARTITION_DREAM(
        dream_inputs,
        inputs.samples_and_matrix.filter{ it[0].method_differential == 'dream' }
    )

    ch_versions = ch_versions.mix( VARIANCEPARTITION_DREAM.out.versions.first() )

    // ----------------------------------------------------
    // Collect results
    // ----------------------------------------------------

    ch_results = DESEQ2_DIFFERENTIAL.out.results
        .mix(LIMMA_DIFFERENTIAL.out.results)
        .mix(PROPR_PROPD.out.results_genewise)
        .mix(VARIANCEPARTITION_DREAM.out.results)

    ch_normalised_matrix = DESEQ2_NORM.out.normalised_counts
        .mix(LIMMA_NORM.out.normalised_counts)

    ch_model = DESEQ2_DIFFERENTIAL.out.model
        .mix(LIMMA_DIFFERENTIAL.out.model)
        .mix(VARIANCEPARTITION_DREAM.out.model)

    ch_variance_stabilised_matrix = DESEQ2_NORM.out.rlog_counts
        .mix(DESEQ2_NORM.out.vst_counts)
        .groupTuple()

    // ----------------------------------------------------
    // Filter DE results
    // ----------------------------------------------------

    ch_diff_filter_params = ch_results
        .join(inputs.filter_params)
        .multiMap { meta, results, filter_meta ->
            def method_params = [
                'deseq2': [
                    fc_column: 'log2FoldChange', fc_cardinality: '>=',
                    stat_column: 'padj', stat_cardinality: '<='
                ],
                'limma' : [
                    fc_column: 'logFC', fc_cardinality: '>=',
                    stat_column: 'adj.P.Val', stat_cardinality: '<='
                ],
                'propd' : [
                    fc_column: 'lfc', fc_cardinality: '>=',
                    stat_column: 'weighted_connectivity', stat_cardinality: '>='
                ],
                'dream' : [
                    fc_column: 'logFC', fc_cardinality: '>=',
                    stat_column: 'adj.P.Val', stat_cardinality: '<='
                ]
            ]
            filter_input: [meta + filter_meta, results]
            fc_input: [
                method_params[meta.method_differential].fc_column,
                filter_meta.fc_threshold,
                method_params[meta.method_differential].fc_cardinality
            ]
            stat_input: [
                method_params[meta.method_differential].stat_column,
                filter_meta.stat_threshold,
                method_params[meta.method_differential].stat_cardinality
            ]
        }

    // Filter differential results
    CUSTOM_FILTERDIFFERENTIALTABLE(
        ch_diff_filter_params.filter_input,
        ch_diff_filter_params.fc_input,
        ch_diff_filter_params.stat_input
    )
    ch_versions = ch_versions.mix(CUSTOM_FILTERDIFFERENTIALTABLE.out.versions.first())

    emit:
    // main results
    results_genewise           = ch_results
    results_genewise_filtered  = CUSTOM_FILTERDIFFERENTIALTABLE.out.filtered

    // pairwise results
    adjacency                  = PROPR_PROPD.out.adjacency

    // other
    normalised_matrix          = ch_normalised_matrix
    variance_stabilised_matrix = ch_variance_stabilised_matrix
    model                      = ch_model
    versions                   = ch_versions
}
