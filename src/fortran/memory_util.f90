!  This file is part of XOPTFOIL.

!  XOPTFOIL is free software: you can redistribute it and/or modify
!  it under the terms of the GNU General Public License as published by
!  the Free Software Foundation, either version 3 of the License, or
!  (at your option) any later version.

!  XOPTFOIL is distributed in the hope that it will be useful,
!  but WITHOUT ANY WARRANTY; without even the implied warranty of
!  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!  GNU General Public License for more details.

!  You should have received a copy of the GNU General Public License
!  along with XOPTFOIL.  If not, see <http://www.gnu.org/licenses/>.

!  Copyright (C) 2017-2019 Daniel Prosser

module memory_util

! Module containing utilities for memory management

  implicit none

  contains

!=============================================================================80
!
! Allocates memory for buffer airfoil
!
!=============================================================================80
subroutine allocate_airfoil(foil)

  use vardef, only : airfoil_type

  type(airfoil_type), intent(inout) :: foil

  integer :: npoint
 
  npoint = foil%npoint
  allocate(foil%x(npoint))
  allocate(foil%z(npoint))

end subroutine allocate_airfoil

!=============================================================================80
!
! Deallocates memory for buffer airfoil
!
!=============================================================================80
subroutine deallocate_airfoil(foil)

  use vardef, only : airfoil_type

  type(airfoil_type), intent(inout) :: foil

  deallocate(foil%x)
  deallocate(foil%z)

end subroutine deallocate_airfoil

!=============================================================================80
!
! Allocates memory for airfoil optimization
!
!=============================================================================80
subroutine allocate_airfoil_data()

  use xfoil_driver,       only : xfoil_init
  use vardef,             only : nparams_top, nparams_bot, shape_functions,    &
                                 xseedt, xseedb, curr_foil
  use parametrization,    only : create_shape_functions

  double precision, dimension(:), allocatable :: modest, modesb

! Allocate shape function setup arrays
if (trim(shape_functions) == 'naca') then
  allocate(modest(nparams_top))
  allocate(modesb(nparams_bot))
  modest(:) = 0.d0
  modesb(:) = 0.d0
else if ((trim(shape_functions) == 'camb-thick') .or.                          &
         (trim(shape_functions) == 'camb-thick-plus')) then
  allocate(modest(nparams_top))
  modest(:) = 0.d0
else
  allocate(modest(nparams_top*3))
  allocate(modesb(nparams_bot*3))
  modest(:) = 0.d0
  modesb(:) = 0.d0
end if

! Allocate private memory for airfoil optimization on each thread

!$omp parallel default(shared)

! For NACA, this will create the shape functions.  For Hicks-Henne,
! it will just allocate them.

call create_shape_functions(xseedt, xseedb, modest, modesb,                  &
                              shape_functions, first_time=.true.)


! Allocate memory for working airfoil on each thread

  curr_foil%npoint = size(xseedt,1) + size(xseedb,1) - 1
  call allocate_airfoil(curr_foil)

! Allocate memory for xfoil

  call xfoil_init()

!$omp end parallel

if ((trim(shape_functions) /= 'camb-thick') .and. & 
    (trim(shape_functions) /= 'camb-thick-plus')) then
! Deallocate shape function setup arrays

  deallocate(modest)
  deallocate(modesb)
end if

end subroutine allocate_airfoil_data

!=============================================================================80
!
! Frees memory used during airfoil optimization
!
!=============================================================================80
subroutine deallocate_airfoil_data()

  use parametrization,    only : deallocate_shape_functions
  use vardef,             only : curr_foil
  use xfoil_driver,       only : xfoil_cleanup

!$omp parallel default(shared)

  call deallocate_shape_functions()
  call deallocate_airfoil(curr_foil)
  call xfoil_cleanup()

!$omp end parallel

end subroutine deallocate_airfoil_data

end module memory_util
