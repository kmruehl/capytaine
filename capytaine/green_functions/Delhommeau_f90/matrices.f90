MODULE MATRICES

  USE CONSTANTS

  USE GREEN_RANKINE
  USE GREEN_WAVE

  IMPLICIT NONE

CONTAINS

  SUBROUTINE ADD_RANKINE_PART_TO_THE_MATRICES(                        &
      nb_faces_1,                                                     &
      centers_1, normals_1,                                           &
      nb_vertices_2, nb_faces_2,                                      &
      vertices_2, faces_2, centers_2, normals_2, areas_2, radiuses_2, &
      coeff,                                                          &
      S, K)

    INTEGER,                                     INTENT(IN) :: nb_faces_1, nb_faces_2, nb_vertices_2
    REAL(KIND=PRE), DIMENSION(nb_faces_1, 3),    INTENT(IN) :: centers_1, normals_1
    REAL(KIND=PRE), DIMENSION(nb_vertices_2, 3), INTENT(IN) :: vertices_2
    INTEGER,        DIMENSION(nb_faces_2, 4),    INTENT(IN) :: faces_2
    REAL(KIND=PRE), DIMENSION(nb_faces_2, 3),    INTENT(IN) :: centers_2, normals_2
    REAL(KIND=PRE), DIMENSION(nb_faces_2),       INTENT(IN) :: areas_2, radiuses_2

    REAL(KIND=PRE), INTENT(IN) :: coeff

    COMPLEX(KIND=PRE), DIMENSION(nb_faces_1, nb_faces_2), INTENT(INOUT) :: S
    COMPLEX(KIND=PRE), DIMENSION(nb_faces_1, nb_faces_2), INTENT(INOUT) :: K

    ! Local variables
    INTEGER :: I, J
    REAL(KIND=PRE)               :: SP1
    REAL(KIND=PRE), DIMENSION(3) :: VSP1

    DO I = 1, nb_faces_1
      !$OMP PARALLEL DO PRIVATE(J, SP1, VSP1)
      DO J = 1, nb_faces_2

        CALL COMPUTE_INTEGRAL_OF_RANKINE_SOURCE( &
          centers_1(I, :),                       &
          vertices_2(faces_2(J, :), :),          &
          centers_2(J, :),                       &
          normals_2(J, :),                       &
          areas_2(J),                            &
          radiuses_2(J),                         &
          SP1, VSP1                              &
          )

        ! Store into influence matrix
        S(I, J) = S(I, J) - coeff * SP1/(4*PI)                                ! Green function
        K(I, J) = K(I, J) - coeff * DOT_PRODUCT(normals_1(I, :), VSP1)/(4*PI) ! Gradient of the Green function

      END DO
      !$OMP END PARALLEL DO
    END DO

  END SUBROUTINE

  ! =====================================================================

  SUBROUTINE ADD_WAVE_PART_TO_THE_MATRICES  &
      (nb_faces_1, centers_1, normals_1, &
      nb_faces_2,                        &
      centers_2, areas_2,                &
      wavenumber, depth,                 &
      XR, XZ, APD,                       &
      NEXP, AMBDA, AR,                   &
      coeff,                             &
      same_body,                         &
      S, K)

    ! Mesh data
    INTEGER,                                  INTENT(IN) :: nb_faces_1, nb_faces_2
    REAL(KIND=PRE), DIMENSION(nb_faces_1, 3), INTENT(IN) :: normals_1, centers_1
    REAL(KIND=PRE), DIMENSION(nb_faces_2, 3), INTENT(IN) :: centers_2
    REAL(KIND=PRE), DIMENSION(nb_faces_2),    INTENT(IN) :: areas_2

    REAL(KIND=PRE),                           INTENT(IN) :: wavenumber, depth

    ! Tabulated integrals
    REAL(KIND=PRE), DIMENSION(328),           INTENT(IN) :: XR
    REAL(KIND=PRE), DIMENSION(46),            INTENT(IN) :: XZ
    REAL(KIND=PRE), DIMENSION(328, 46, 2, 2), INTENT(IN) :: APD

    ! Prony decomposition for finite depth
    INTEGER,                                  INTENT(IN) :: NEXP
    REAL(KIND=PRE), DIMENSION(NEXP),          INTENT(IN) :: AMBDA, AR

    REAL(KIND=PRE), INTENT(IN) :: coeff

    ! Trick to save some time
    LOGICAL,                                  INTENT(IN) :: same_body

    ! Output
    COMPLEX(KIND=PRE), DIMENSION(nb_faces_1, nb_faces_2), INTENT(INOUT) :: S
    COMPLEX(KIND=PRE), DIMENSION(nb_faces_1, nb_faces_2), INTENT(INOUT) :: K

    ! Local variables
    INTEGER                         :: I, J
    COMPLEX(KIND=PRE)               :: SP2
    COMPLEX(KIND=PRE), DIMENSION(3) :: VSP2_SYM, VSP2_ANTISYM

    IF (SAME_BODY) THEN
      ! If we are computing the influence of some cells upon themselves, the resulting matrices have some symmetries.
      ! This is due to the symmetry of the Green function, and the way the integral on the face is approximated.
      ! (More precisely, the Green function is symmetric and its derivative is the sum of a symmetric part and an anti-symmetric
      ! part.)

      DO I = 1, nb_faces_1
        !$OMP PARALLEL DO PRIVATE(J, SP2, VSP2_SYM, VSP2_ANTISYM)
        DO J = I, nb_faces_2

          IF (depth == INFINITE_DEPTH) THEN
            CALL WAVE_PART_INFINITE_DEPTH &
              (wavenumber,                &
              centers_1(I, :),            &
              centers_2(J, :),            &
              XR, XZ, APD,                &
              SP2, VSP2_SYM               &
              )
            VSP2_ANTISYM(:) = ZERO
          ELSE
            CALL WAVE_PART_FINITE_DEPTH   &
              (wavenumber,                &
              centers_1(I, :),            &
              centers_2(J, :),            &
              depth,                      &
              XR, XZ, APD,                &
              NEXP, AMBDA, AR,            &
              SP2, VSP2_SYM, VSP2_ANTISYM &
              )
          END IF

          S(I, J) = S(I, J) - coeff/(4*PI) * SP2*areas_2(J)
          K(I, J) = K(I, J) - coeff/(4*PI) * DOT_PRODUCT(normals_1(I, :),         &
            VSP2_SYM + VSP2_ANTISYM) &
            *areas_2(J)

          IF (.NOT. I==J) THEN
            VSP2_SYM(1:2) = -VSP2_SYM(1:2)
            S(J, I) = S(J, I) - coeff/(4*PI) * SP2*areas_2(I)
            K(J, I) = K(J, I) - coeff/(4*PI) * DOT_PRODUCT(normals_1(J, :),         &
              VSP2_SYM - VSP2_ANTISYM) &
              *areas_2(I)
          END IF

        END DO
        !$OMP END PARALLEL DO
      END DO

    ELSE
      ! General case: if we are computing the influence of a some cells on other cells, we have to compute all the coefficients.

      DO I = 1, nb_faces_1
        !$OMP PARALLEL DO PRIVATE(J, SP2, VSP2_SYM, VSP2_ANTISYM)
        DO J = 1, nb_faces_2

          IF (depth == INFINITE_DEPTH) THEN
            CALL WAVE_PART_INFINITE_DEPTH &
              (wavenumber,                &
              centers_1(I, :),            &
              centers_2(J, :),            &
              XR, XZ, APD,                &
              SP2, VSP2_SYM               &
              )
            VSP2_ANTISYM(:) = ZERO
          ELSE
            CALL WAVE_PART_FINITE_DEPTH   &
              (wavenumber,                &
              centers_1(I, :),            &
              centers_2(J, :),            &
              depth,                      &
              XR, XZ, APD,                &
              NEXP, AMBDA, AR,            &
              SP2, VSP2_SYM, VSP2_ANTISYM &
              )
          END IF

          S(I, J) = S(I, J) - coeff/(4*PI) * SP2*areas_2(J)                                ! Green function
          K(I, J) = K(I, J) - coeff/(4*PI) * DOT_PRODUCT(normals_1(I, :),         &
            VSP2_SYM + VSP2_ANTISYM) &
            *areas_2(J) ! Gradient of the Green function

        END DO
        !$OMP END PARALLEL DO
      END DO
    END IF

  END SUBROUTINE

  ! =====================================================================

  SUBROUTINE BUILD_MATRICES(                          &
      nb_faces_1, centers_1, normals_1,               &
      nb_vertices_2, nb_faces_2, vertices_2, faces_2, &
      centers_2, normals_2, areas_2, radiuses_2,      &
      wavenumber, depth,                              &
      coeffs,                                         &
      XR, XZ, APD,                                    &
      NEXP, AMBDA, AR,                                &
      same_body,                                      &
      S, K)

    ! Mesh data
    INTEGER,                                     INTENT(IN) :: nb_faces_1, nb_faces_2, nb_vertices_2
    REAL(KIND=PRE), DIMENSION(nb_faces_1, 3),    INTENT(IN) :: centers_1, normals_1
    REAL(KIND=PRE), DIMENSION(nb_vertices_2, 3), INTENT(IN) :: vertices_2
    INTEGER,        DIMENSION(nb_faces_2, 4),    INTENT(IN) :: faces_2
    REAL(KIND=PRE), DIMENSION(nb_faces_2, 3),    INTENT(IN) :: centers_2, normals_2
    REAL(KIND=PRE), DIMENSION(nb_faces_2),       INTENT(IN) :: areas_2, radiuses_2

    LOGICAL,                                  INTENT(IN) :: same_body

    REAL(KIND=PRE),                           INTENT(IN) :: wavenumber, depth

    REAL(KIND=PRE), DIMENSION(3) :: coeffs

    ! Tabulated integrals
    REAL(KIND=PRE), DIMENSION(328),           INTENT(IN) :: XR
    REAL(KIND=PRE), DIMENSION(46),            INTENT(IN) :: XZ
    REAL(KIND=PRE), DIMENSION(328, 46, 2, 2), INTENT(IN) :: APD

    ! Prony decomposition for finite depth
    INTEGER,                                  INTENT(IN) :: NEXP
    REAL(KIND=PRE), DIMENSION(NEXP),          INTENT(IN) :: AMBDA, AR

    ! Output
    COMPLEX(KIND=PRE), DIMENSION(nb_faces_1, nb_faces_2), INTENT(OUT) :: S
    COMPLEX(KIND=PRE), DIMENSION(nb_faces_1, nb_faces_2), INTENT(OUT) :: K

    ! Local variables
    INTEGER :: I
    REAL(KIND=PRE), DIMENSION(nb_faces_1, 3) :: reflected_centers_1, reflected_normals_1


    !!!!!!!!!!!!!!!!!!!!
    !  Initialization  !
    !!!!!!!!!!!!!!!!!!!!

    S(:, :) = CMPLX(0.0, 0.0, KIND=PRE)
    K(:, :) = CMPLX(0.0, 0.0, KIND=PRE)


    !!!!!!!!!!!!!!!!!!
    !  Rankine part  !
    !!!!!!!!!!!!!!!!!!

    IF (coeffs(1) .NE. ZERO) THEN
      CALL ADD_RANKINE_PART_TO_THE_MATRICES(                            &
        nb_faces_1,                                                     &
        centers_1, normals_1,                                           &
        nb_vertices_2, nb_faces_2,                                      &
        vertices_2, faces_2, centers_2, normals_2, areas_2, radiuses_2, &
        coeffs(1),                                                      &
        S, K)
    END IF


    !!!!!!!!!!!!!!!!!!!!!!!!!!!!
    !  Reflected Rankine part  !
    !!!!!!!!!!!!!!!!!!!!!!!!!!!!

    IF (coeffs(2) .NE. ZERO) THEN

      IF (depth == INFINITE_DEPTH) THEN
        ! Reflection through free surface
        reflected_centers_1(:, 1:2) = centers_1(:, 1:2)
        reflected_centers_1(:, 3)   = -centers_1(:, 3)
      ELSE
        ! Reflection through sea bottom
        reflected_centers_1(:, 1:2) = centers_1(:, 1:2)
        reflected_centers_1(:, 3)   = -centers_1(:, 3) - 2*depth
      END IF

      reflected_normals_1(:, 1:2) = normals_1(:, 1:2)
      reflected_normals_1(:, 3)   = -normals_1(:, 3)

      CALL ADD_RANKINE_PART_TO_THE_MATRICES(                            &
        nb_faces_1,                                                     &
        reflected_centers_1, reflected_normals_1,                       &
        nb_vertices_2, nb_faces_2,                                      &
        vertices_2, faces_2, centers_2, normals_2, areas_2, radiuses_2, &
        coeffs(2),                                                      &
        S, K)

    END IF

    !!!!!!!!!!!!!!!
    !  Wave part  !
    !!!!!!!!!!!!!!!

    IF (coeffs(3) .NE. ZERO) THEN

      CALL ADD_WAVE_PART_TO_THE_MATRICES(  &
        nb_faces_1, centers_1, normals_1,  &
        nb_faces_2,                        &
        centers_2, areas_2,                &
        wavenumber, depth,                 &
        XR, XZ, APD,                       &
        NEXP, AMBDA, AR,                   &
        coeffs(3),                         &
        same_body,                         &
        S, K)

    END IF

    !!!!!!!!!!!!!

    IF (SAME_BODY) THEN
      DO I = 1, nb_faces_1
        K(I, I) = K(I, I) + 0.5
      END DO
    END IF

    RETURN

  END SUBROUTINE

  ! =====================================================================

END MODULE MATRICES
