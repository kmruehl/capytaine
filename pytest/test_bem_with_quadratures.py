#!/usr/bin/env python
# coding: utf-8

import numpy as np
import xarray as xr
import capytaine as cpt
import quadpy

def test_area():
    mesh = cpt.Sphere().mesh

    for quadrature in [quadpy.quadrilateral.sommariva_05(), quadpy.quadrilateral.stroud_c2_7_2()]:
        mesh.compute_quadrature(quadrature)
        for i_face in range(mesh.nb_faces):
            assert np.isclose(np.sum(mesh.quadrature_points[1][i_face, :]), mesh.faces_areas[i_face], rtol=1e-2)


def test_resolution():
    cylinder = cpt.HorizontalCylinder(
        length=5.0, radius=1.0,
        center=(0, 0, -2),
        nr=2, nx=10, ntheta=5,
    )
    # cylinder.show()
    cylinder.add_translation_dof(name="Heave")

    test_matrix = xr.Dataset(coords={
        "omega": np.linspace(0.5, 3.0, 2),
        "radiating_dof": ["Heave"],
    })

    solver = cpt.BEMSolver()

    cylinder.mesh.compute_quadrature(quadpy.quadrilateral.sommariva_01())
    data_1 = solver.fill_dataset(test_matrix, [cylinder])

    cylinder.mesh.compute_quadrature(quadpy.quadrilateral.sommariva_03())
    data_3 = solver.fill_dataset(test_matrix, [cylinder])

    assert np.allclose(data_1["added_mass"].data, data_3["added_mass"].data, rtol=1e-2)

