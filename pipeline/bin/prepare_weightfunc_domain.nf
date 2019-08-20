
// Prepares the weight function on the mesh surface and the domain for optimization.


// INPUTS
// out                      Output folder containing ciftify and meshing outputs

// IMPLICIT configuration variables (overrideable)
// clean_cfg                Surface-based cleaning configuration file

// OUTPUTS
// Numpy file with quadratic surface constants
// Numpy file containing nodal weights
// Transformation affine for mapping quadratic domain inputs to sampling surface
// Nodal weights

// INPUT SPECIFICATION
//Check input parameters
if (!params.out){

    log.info('Insufficient input specification!')
    log.info('Needs --out!')
    log.info('Exiting...')
    System.exit(1)

}

//if (!params.template_dir) {
//
//    log.info("Insufficient input specification!"    )
//    log.info('Needs --template_dir!')
//    log.info('Exiting...')
//    System.exit(1)
//
//}
//////////////////////////////////////////////////////////

// MAIN PROCESSES

// Get a list of all subjects with mesh generated
println(params.out) 
sim_mesh_dirs = "$params.out/ciftify/sub-*"

weightfunc_input = Channel.create()
affine_extract_input = Channel.create()

weightfunc_subs = Channel.fromPath(sim_mesh_dirs, type: 'dir')
                    .map { n -> n.getBaseName() }
                    .tap ( weightfunc_input )
                    .map { n -> [
                                    n,
                                    file("$params.out/sim_mesh/$n/${n}_T1fs_conform.nii.gz")
                                ]
                         }
                    .tap ( affine_extract_input )

// Compute weighting function to use give the output file!
process compute_weightfunc {

    echo true

    input:
    val sub from weightfunc_input

    output:
    set val(sub), file("*${params.outfile}") into weightfunc_outputs

    //Run custom function
    shell:
    '''
    !{params.weightfunc} !{params.out} !{sub} !{params.outfile}
    '''

}

// If more than one file, take the average between them
process combine_weightfiles {

    echo true
    module 'connectome-workbench'

    input:
    set val(sub), file("input*") from weightfunc_outputs

    output:
    set val(sub), file("combined_${params.outfile}") into weightfiles

    
    shell:
    '''
    find input* | xargs -I {} echo -cifti {} | \
       xargs wb_command -cifti-average combined_!{params.outfile}
    '''

}

//Resample data into SimNIBS space
process weightfunc_to_tetra {

    echo true
    module 'connectome-workbench'

    input:
    set val(sub), file("combined_${params.outfile}") from weightfiles
    file output from file(params.out)

    output:
    set val(sub), file("weight.mesh.dscalar.nii") into resamp_weightfiles

    shell:
    '''
    #Split up dscalar file (which contains volume but like, idk rn)
    wb_command -cifti-separate \
                combined_!{params.outfile} \
                COLUMN \
                -metric CORTEX_RIGHT weight.R.shape.gii \
                -metric CORTEX_LEFT  weight.L.shape.gii

    #Do resampling
    mninonlin=!{output}/ciftify/!{sub}/MNINonLinear/fsaverage_LR32k/
    registration=!{output}/registration/!{sub}/
    wb_command -metric-resample \
                weight.R.shape.gii \
                $mninonlin/!{sub}.R.sphere.32k_fs_LR.surf.gii \
                $registration/!{sub}.R.sphere.reg_msm.surf.gii \
                BARYCENTRIC \
                weight.R.mesh.shape.gii 

    wb_command -metric-resample \
                weight.L.shape.gii \
                $mninonlin/!{sub}.L.sphere.32k_fs_LR.surf.gii \
                $registration/!{sub}.L.sphere.reg_msm.surf.gii \
                BARYCENTRIC \
                weight.L.mesh.shape.gii


    #Combine and pass? 
    wb_command -cifti-create-dense-scalar    \
                -left-metric weight.L.mesh.shape.gii \
                -right-metric weight.R.mesh.shape.gii \
                weight.mesh.dscalar.nii
                
    '''

}


// Using the weight function, find the centre of mass using a user-provided function
process calculate_CoM {

    echo true
    module 'connectome-workbench'

    input:
    set val(sub), file("weight.mesh.dscalar.nii") from resamp_weightfiles
    file output from file(params.out)
    
    output:
    set val(sub), file("centre_coordinate.txt") into com_out


    shell:
    '''
    !{params.massfunc} weight.mesh.dscalar.nii !{output} !{sub} "centre_coordinate.txt"
    '''

}


// Extract affine transformation matrix using ciftify output
process extract_affine {

    input:
    set val(sub), file("t1fs.nii.gz") from affine_extract_input

    output:
    set val(sub), file("affine") into affines
    

    shell:
    '''
    #!/usr/bin/env python


    import nibabel as nib
    import numpy as np
    import os

    img = nib.load("t1fs.nii.gz")
    affine = img.affine    
    affine.tofile("affine")
    '''
}

// Make a channel with mesh, affine, and centroid inputs
surface_patch_input = com_out
                        .map { s,c ->   [
                                            s,
                                            c,
                                            file("$params.out/sim_mesh/$s/${s}.msh")
                                        ]
                             }
                        .join ( affines )
//                        .subscribe { log.info("$it") }


// Make a surface patch 
process make_surface_patch {

    input:
    set val(sub), file("coordinate.txt"), file("data.msh"), file("affine") from surface_patch_input

    output:
    set val(sub), file("patch_dilated_coords"), file("patch_mean_norm") into surface_patch

    """
    extract_surface_patch.py "data.msh" "affine" "coordinate.txt" "patch" 
    """

}


// Parameterize the surface patch using quadratic fit
process parameterize_surface {

    input:
    set val(sub), file("patch"), file("norm") from surface_patch

    output:
    set val(sub), file("surf_C"), file("surf_R"), file("surf_bounds") into param_surf

    """
    parameterize_surface_patch.py "patch" "norm" "surf"
    """

}

// Prepare tetrahedral weights using projection algorithm
