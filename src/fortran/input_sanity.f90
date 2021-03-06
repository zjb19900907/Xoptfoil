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

module input_sanity

  implicit none

  contains

!=============================================================================80
!
! Checks that the seed airfoil passes all constraints, sets scale factors for
! objective functions at each operating point, and optionally sets the
! minimum allowable pitching moment.
!
!=============================================================================80
subroutine check_seed()

  use vardef
  use math_deps,          only : interp_vector, curvature, derv1f1, derv1b1, norm_2
  use math_deps,          only : interp_point, derivation_at_point
  use xfoil_driver,       only : run_xfoil
  use xfoil_inc,          only : AMAX, CAMBR
  use airfoil_evaluation, only : xfoil_options, xfoil_geom_options, op_seed_value
  use airfoil_operations, only : assess_surface, smooth_it, my_stop, rebuild_airfoil
  use airfoil_operations, only : get_curv_violations, show_reversals_highlows
  use os_util,            only : print_note


  double precision, dimension(:), allocatable :: x_interp, thickness
  double precision, dimension(:), allocatable :: zt_interp, zb_interp
  double precision, dimension(naddthickconst) :: add_thickvec
  double precision, dimension(noppoint)       :: lift, drag, moment, viscrms, alpha, &
                                                  xtrt, xtrb
  double precision :: penaltyval, tegap, gapallow, maxthick, heightfactor
  double precision :: panang1, panang2, maxpanang, slope
  double precision :: checkval, len1, len2, growth1, growth2, xtrans
  double precision :: pi
  integer :: i, nptt, nptb, nptint
  character(100) :: text, text2
  character(15) :: opt_type
  logical :: addthick_violation
  double precision :: ref_value, seed_value, tar_value, match_delta, cur_te_curvature

  penaltyval = 0.d0
  pi = acos(-1.d0)
  nptt = size(xseedt,1)
  nptb = size(xseedb,1)


  write(*,*) 'Checking to make sure seed airfoil passes all constraints ...'


! Smooth surfaces of airfoil *before* other checks are made

  if (do_smoothing) then
    write (*,*) 
    write (*,'(1x,A)') 'Smoothing Top surface ...'
    call smooth_it (show_details, xseedt, zseedt) 

    write (*,*) 
    write (*,'(1x,A)') 'Smoothing Bottom surface ...'
    call smooth_it (show_details, xseedb, zseedb)
  end if

  write(*,*)

! Get allowable panel growth rate

  growth_allowed = 0.d0

! Top surface growth rates

  len1 = sqrt((xseedt(2)-xseedt(1))**2.d0 + (zseedt(2)-zseedt(1))**2.d0)
  do i = 2, nptt - 1
    len2 = sqrt((xseedt(i+1)-xseedt(i))**2.d0 + (zseedt(i+1)-zseedt(i))**2.d0)
    growth1 = len2/len1
    growth2 = len1/len2
    if (max(growth1,growth2) > growth_allowed)                                 &
        growth_allowed = 1.5d0*max(growth1,growth2)
    len1 = len2
  end do

! Bottom surface growth rates

  len1 = sqrt((xseedb(2)-xseedb(1))**2.d0 + (zseedb(2)-zseedb(1))**2.d0)
  do i = 2, nptb - 1
    len2 = sqrt((xseedb(i+1)-xseedb(i))**2.d0 + (zseedb(i+1)-zseedb(i))**2.d0)
    growth1 = len2/len1
    growth2 = len1/len2
    if (max(growth1,growth2) > growth_allowed)                               &
        growth_allowed = 1.5d0*max(growth1,growth2)
    len1 = len2
  end do

! Rebuild foil out of top and bot

  call rebuild_airfoil (xseedt, xseedb, zseedt, zseedb, curr_foil)

  
! Too blunt or sharp leading edge

  panang1 = atan((zseedt(2)-zseedt(1))/(xseedt(2)-xseedt(1))) *                &
            180.d0/acos(-1.d0)
  panang2 = atan((zseedb(1)-zseedb(2))/(xseedb(2)-xseedb(1))) *                &
            180.d0/acos(-1.d0)
  maxpanang = max(panang2,panang1)

  if (maxpanang > 89.99d0) then
    write(text,'(F8.4)') maxpanang
    text = adjustl(text)
    write(*,*) "LE panel angle: "//trim(text)//" degrees"
    call ask_stop("Seed airfoil's leading edge is too blunt.")
  end if
  if (abs(panang1 - panang2) > 20.d0) then
    write(text,'(F8.4)') abs(panang1 - panang2)
    text = adjustl(text)
    write(*,*) "LE panel angle: "//trim(text)//" degrees"
    call ask_stop("Seed airfoil's leading edge is too sharp.")
  end if

! Too high curvature at TE - TE panel problem 
!    In the current Hicks Henne shape functions implementation, the last panel is
!    forced to become TE which can lead to a thick TE area with steep last panel(s)
!       (see create_shape ... do j = 2, npt-1 ...)
!    so the curvature (2nd derivative) at the last 10 panels is checked

  if (check_curvature) then
    cur_te_curvature = maxval (abs(curvature(11, xseedt(nptt-10:nptt), zseedt(nptt-10:nptt))))
    if (cur_te_curvature  > max_te_curvature) then 
      write(text,'(F8.4)') cur_te_curvature
      text = adjustl(text)
      call ask_stop("Curvature of "//trim(text)// &
                    " on top surface at trailing edge violates max_te_curvature constraint.")
    end if 

    cur_te_curvature = maxval (abs(curvature(11, xseedb(nptb-10:nptb), zseedb(nptb-10:nptb))))
    if (cur_te_curvature  > max_te_curvature) then 
      write(text,'(F8.4)') cur_te_curvature
      text = adjustl(text)
      call ask_stop("Curvature of "//trim(text)// &
                    " on bottom surface at trailing edge violates max_te_curvature constraint.")
    end if 
  end if 

! Interpolate either bottom surface to top surface x locations or vice versa
! to determine thickness

  if (xseedt(nptt) <= xseedb(nptb)) then
    allocate(x_interp(nptt))
    allocate(zt_interp(nptt))
    allocate(zb_interp(nptt))
    allocate(thickness(nptt))
    nptint = nptt
    call interp_vector(xseedb, zseedb, xseedt, zb_interp)
    x_interp = xseedt
    zt_interp = zseedt
  else
    allocate(x_interp(nptb))
    allocate(zt_interp(nptb))
    allocate(zb_interp(nptb))
    allocate(thickness(nptb))
    nptint = nptb
    call interp_vector(xseedt, zseedt, xseedb, zt_interp)
    x_interp = xseedb
    zb_interp = zseedb
  end if

! Compute thickness parameters

  tegap = zseedt(nptt) - zseedb(nptb)
  maxthick = 0.d0
  heightfactor = tan(min_te_angle*acos(-1.d0)/180.d0/2.d0)

  do i = 2, nptint - 1

!   Thickness array and max thickness
    
    thickness(i) = zt_interp(i) - zb_interp(i)
    if (thickness(i) > maxthick) maxthick = thickness(i)

!   Check if thinner than specified wedge angle on back half of airfoil
    
    if (x_interp(i) > 0.5d0) then
      gapallow = tegap + 2.d0 * heightfactor * (x_interp(nptint) -             &
                                                x_interp(i))
      if (thickness(i) < gapallow) then
        ! jx-mod removed scale and xoffset
        ! xtrans = x_interp(i)/foilscale - xoffset
        xtrans = x_interp(i)
        write(text,'(F8.4)') xtrans
        text = adjustl(text)
        write(*,*) "Detected too thin at x = "//trim(text)
        penaltyval = penaltyval + (gapallow - thickness(i))/0.1d0
      end if
    end if

  end do

! Too thin on back half

  if (penaltyval > 0.d0)                                                       &
     call ask_stop("Seed airfoil is thinner than min_te_angle near the "//&
                   "trailing edge.")
  penaltyval = 0.d0

! Check additional thickness constraints

  if (naddthickconst > 0) then
    call interp_vector(x_interp, thickness,                                    &
                       addthick_x(1:naddthickconst), add_thickvec)

    addthick_violation = .false.
    do i = 1, naddthickconst
      if ( (add_thickvec(i) < addthick_min(i)) .or.                            &
           (add_thickvec(i) > addthick_max(i)) ) then
        addthick_violation = .true.
        write(text,'(F8.4)') addthick_x(i)
        text = adjustl(text)
        write(text2,'(F8.4)') add_thickvec(i)
        text2 = adjustl(text2)
        write(*,*) "Thickness at x = "//trim(text)//": "//trim(text2)
      end if
    end do

    if (addthick_violation)                                                    &
      call ask_stop("Seed airfoil violates one or more thickness constraints.")

  end if

! Max thickness too low

  if (maxthick < min_thickness) then
    write(text,'(F8.4)') maxthick
    text = adjustl(text)
    write(*,*) "Thickness: "//trim(text)
    call ask_stop("Seed airfoil violates min_thickness constraint.")
  end if

! Max thickness too high

  if (maxthick > max_thickness) then
    write(text,'(F8.4)') maxthick
    text = adjustl(text)
    write(*,*) "Thickness: "//trim(text)
    call ask_stop("Seed airfoil violates max_thickness constraint.")
  end if


! Check for curvature reversals

  if (check_curvature) then

    call check_handle_curve_violations ('Top surface', xseedt, zseedt, &
                                        max_curv_reverse_top, max_curv_highlow_top)
    call check_handle_curve_violations ('Bot surface', xseedb, zseedb, &
                                        max_curv_reverse_bot, max_curv_highlow_bot)
  end if 


! If mode match_foils end here with checks as it becomes aero specific, calc scale

  if (match_foils) then
    match_delta = norm_2(zseedt(2:nptt-1) - zmatcht(2:nptt-1)) + &
                  norm_2(zseedb(2:nptb-1) - zmatchb(2:nptb-1))
    ! Playground: Match foil equals seed foil. Take a dummy objective value to start
    if (match_delta < 1d-10) then 
      call ask_stop('Match foil and seed foil are equal. A dummy initial value '// &
                     'for the objective function will be taken for demo')
      match_delta = 1d-1 
    end if
    match_foils_scale_factor = 1.d0 / match_delta
    return
  end if 


! Check for bad combinations of operating conditions and optimization types

  do i = 1, noppoint
    write(text,*) i
    text = adjustl(text)

    opt_type = optimization_type(i)
    if ((op_point(i) <= 0.d0) .and. (op_mode(i) == 'spec-cl')) then
      if ( (trim(opt_type) /= 'min-drag') .and.                                &
           (trim(opt_type) /= 'max-xtr') .and.                                 &
            ! jx-mod - allow geo target and min-lift-slope, min-glide-slope
           (trim(opt_type) /= 'target-drag') .and.                             &
           (trim(opt_type) /= 'target-max-drag') .and.                            &
           (trim(opt_type) /= 'min-lift-slope') .and.                          &
           (trim(opt_type) /= 'min-glide-slope') .and.                         &
           (trim(opt_type) /= 'max-lift-slope') ) then
        write(*,*) "Error: operating point "//trim(text)//" is at Cl = 0. "//  &
                 "Cannot use '"//trim(opt_type)//"' optimization in this case."
        write(*,*) 
        stop
      end if
    elseif ((op_mode(i) == 'spec-cl') .and.                                    &
            (trim(optimization_type(i)) == 'max-lift')) then
      write(*,*) "Error: Cl is specified for operating point "//trim(text)//   &
                 ". Cannot use 'max-lift' optimization type in this case."
      write(*,*) 
      stop
    elseif ((op_mode(i) == 'spec-cl') .and.                                    &
           (trim(optimization_type(i)) == 'target-lift')) then              
      write (*,*) ("op_mode = 'spec_cl' doesn't make sense "//                &
                   "for optimization_type 'target-lift'")
      write(*,*) 
      stop
    end if

  end do

  ! jx-mod Check for a good value of xfoil vaccel to ensure convergence at higher cl
  if (xfoil_options%vaccel > 0.01d0) then
    write(text,'(F8.4)') xfoil_options%vaccel
    text = adjustl(text)
    call print_note ("The xfoil convergence paramter vaccel: "//trim(text)// &
                     " should be less then 0.01 to avoid convergence problems.")
  end if


! Analyze airfoil at requested operating conditions with Xfoil

  call run_xfoil(curr_foil, xfoil_geom_options, op_point(1:noppoint),          &
                 op_mode(1:noppoint), re(1:noppoint), ma(1:noppoint),          &
                 use_flap, x_flap, y_flap, y_flap_spec,                        &
                 flap_degrees(1:noppoint), xfoil_options, lift, drag, moment,  &
                 viscrms, alpha, xtrt, xtrb, ncrit_pt)

! Penalty for too large panel angles
! jx-mod increased from 25 30
  if (AMAX > 30.d0) then
    write(text,'(F8.4)') AMAX
    text = adjustl(text)
    write(*,*) "Max panel angle: "//trim(text)
    call ask_stop("Seed airfoil panel angles are too large. Try adjusting "//&
                  "xfoil_paneling_options.")
  end if

! Camber too high

  if (CAMBR > max_camber) then
    write(text,'(F8.4)') CAMBR
    text = adjustl(text)
    write(*,*) "Camber: "//trim(text)
    call ask_stop("Seed airfoil violates max_camber constraint.")
  end if

! Camber too low

  if (CAMBR < min_camber) then
    write(text,'(F8.4)') CAMBR
    text = adjustl(text)
    write(*,*) "Camber: "//trim(text)
    call ask_stop("Seed airfoil violates min_camber constraint.")
  end if

! jx-mod Geo targets start -------------------------------------------------

! Evaluate seed value of geomtry targets and scale factor 
  
  do i = 1, ngeo_targets

    select case (trim(geo_targets(i)%type))

      case ('zTop')           ! get z_value top side 
        seed_value = interp_point(x_interp, zt_interp, geo_targets(i)%x)
        ref_value  = interp_point(x_interp, thickness, geo_targets(i)%x)
      case ('zBot')           ! get z_value bot side
        seed_value = interp_point(x_interp, zb_interp, geo_targets(i)%x)
        ref_value  = interp_point(x_interp, thickness, geo_targets(i)%x)
      case ('Thickness')      ! take foil thickness calculated above
        seed_value = maxthick
        ref_value  = maxthick
      case ('Camber')         ! take xfoil camber from  above
        seed_value = CAMBR
        ref_value  = CAMBR
      case default
        call my_stop("Unknown target_type '"//trim(geo_targets(i)%type))
    end select

    geo_targets(i)%seed_value      = seed_value
    geo_targets(i)%reference_value = ref_value

    ! target value negative?  --> take current seed value * |target_value| 
    if (geo_targets(i)%target_value <= 0.d0)                                  &
        geo_targets(i)%target_value = seed_value * abs(geo_targets(i)%target_value)
    tar_value = geo_targets(i)%target_value

    ! will scale objective to 1 ( = no improvement) 
    geo_targets(i)%scale_factor = 1 / ( ref_value + abs(tar_value - seed_value))

  end do 

! Free memory

  deallocate(x_interp)
  deallocate(zt_interp)
  deallocate(zb_interp)
  deallocate(thickness)

! jx-mod Geo targets - end --------------------------------------------


! Check for unconverged points

  do i = 1, noppoint
    if (viscrms(i) > 1.0D-04) then
      write(text,*) i
      text = adjustl(text)
      call ask_stop("Xfoil calculations did not converge for operating "//&
                    "point "//trim(text)//".")
    end if
  end do

! Set moment constraint or check for violation of specified constraint

  do i = 1, noppoint
    if (trim(moment_constraint_type(i)) == 'use_seed') then
      min_moment(i) = moment(i)
    elseif (trim(moment_constraint_type(i)) == 'specify') then
      if (moment(i) < min_moment(i)) then
        write(text,'(F8.4)') moment(i)
        text = adjustl(text)
        write(*,*) "Moment: "//trim(text)
        write(text,*) i
        text = adjustl(text)
        call ask_stop("Seed airfoil violates min_moment constraint for "//&
                      "operating point "//trim(text)//".")
      end if
    end if
  end do

! Evaluate objectives to establish scale factors for each point

  do i = 1, noppoint
    write(text,*) i
    text = adjustl(text)

    if (lift(i) <= 0.d0 .and. (trim(optimization_type(i)) == 'min-sink' .or.   &
        trim(optimization_type(i)) == 'max-glide') ) then
      write(*,*) "Error: operating point "//trim(text)//" has Cl <= 0. "//     &
                 "Cannot use "//trim(optimization_type(i))//" optimization "// &
                 "in this case."
      write(*,*)
      stop
    end if

    if (trim(optimization_type(i)) == 'min-sink') then
      checkval   = drag(i)/lift(i)**1.5d0
      seed_value = lift(i) ** 1.5d0 / drag(i) 

    elseif (trim(optimization_type(i)) == 'max-glide') then
      checkval   = drag(i)/lift(i)
      seed_value = lift(i) / drag(i) 

    elseif (trim(optimization_type(i)) == 'min-drag') then
      checkval   = drag(i)
      seed_value = drag(i) 

    ! Op point type 'target-....'
    !      - minimize the difference between current value and target value
    !      - target_value negative?  --> take current seed value * |target_value| 

    elseif (trim(optimization_type(i)) == 'target-drag') then
      if (target_value(i) < 0.d0) target_value(i) = drag(i) * abs(target_value(i))
 
      checkval   = target_value(i) + ABS (target_value(i)-drag(i))
      seed_value = drag(i)

    elseif (trim(optimization_type(i)) == 'target-max-drag') then
      if (target_value(i) < 0.d0) target_value(i) = drag(i) * abs(target_value(i))

      checkval = max(target_value(i),drag(i))
      seed_value = drag(i)

    elseif (trim(optimization_type(i)) == 'target-lift') then
      if (target_value(i) < 0.d0) target_value(i) = lift(i) * abs(target_value(i))
      ! add a constant base value to the lift difference so the relative change won't be to high
      checkval   = 1.d0 + ABS (target_value(i)-lift(i))
      seed_value = lift(i)

    elseif (trim(optimization_type(i)) == 'target-moment') then
      if (target_value(i) < 0.d0) target_value(i) = moment(i) * abs(target_value(i)) 
      ! add a base value (Clark y or so ;-) to the moment difference so the relative change won't be to high
      checkval   = ABS (target_value(i)-moment(i)) + 0.05d0
      seed_value = moment(i) 

    elseif (trim(optimization_type(i)) == 'max-lift') then
      checkval   = 1.d0/lift(i)
      seed_value = lift(i) 

    elseif (trim(optimization_type(i)) == 'max-xtr') then
      checkval   = 1.d0/(0.5d0*(xtrt(i)+xtrb(i))+0.1d0)  ! Ensure no division by 0
      seed_value = 0.5d0*(xtrt(i)+xtrb(i))

! jx-mod Following optimization based on slope of the curve of op_point
!         convert alpha in rad to get more realistic slope values
!         convert slope in rad to get a linear target 
!         factor 4.d0*pi to adjust range of objective function (not negative)

    elseif (trim(optimization_type(i)) == 'max-lift-slope') then
    ! Maximize dCl/dalpha (0.1 factor to ensure no division by 0)
      slope = derivation_at_point (noppoint, i, (alpha * pi/180.d0) , lift)
      checkval   = 1.d0 / (atan(abs(slope))  + 2.d0*pi)
      seed_value = atan(abs(slope))

    elseif (trim(optimization_type(i)) == 'min-lift-slope') then
    ! jx-mod  New: Minimize dCl/dalpha e.g. to reach clmax at alpha(i) 
      slope = derivation_at_point (noppoint, i,  (alpha * pi/180.d0) , lift)
      checkval   = atan(abs(slope)) + 2.d0*pi
      seed_value = atan(abs(slope))

    elseif (trim(optimization_type(i)) == 'min-glide-slope') then
    ! jx-mod  New: Minimize d(cl/cd)/dcl e.g. to reach best glide at alpha(i) 
      slope = derivation_at_point (noppoint, i,  (lift * 20d0), (lift/drag))
      checkval   = atan(abs(slope)) + 2.d0*pi
      seed_value = atan(abs(slope)) 
     
    else
      write(*,*)
      write(*,*) "Error: requested optimization_type for operating point "//   &
                 trim(text)//" not recognized."
      stop
    end if
    scale_factor(i)  = 1.d0/checkval
    op_seed_value(i) = seed_value
  end do

end subroutine check_seed

!=============================================================================80
!
! Asks user to stop or continue
!
!=============================================================================80
subroutine ask_stop(message)

  use os_util, only: print_error, print_warning

  character(*), intent(in) :: message

  character :: choice
  logical :: valid_choice

! Get user input

  valid_choice = .false.
  do while (.not. valid_choice)
  
    if (len(trim(message)) > 0) call print_warning (message)

    write(*,'(/,1x,A)', advance='no') 'Continue anyway? (y/n): '
    read(*,'(A)') choice

    if ( (choice == 'y') .or. (choice == 'Y') ) then
      valid_choice = .true.
      choice = 'y'
    else if ( ( choice == 'n') .or. (choice == 'N') ) then
      valid_choice = .true.
      choice = 'n'
    else
      write(*,'(A)') 'Please enter y or n.'
      valid_choice = .false.
    end if

  end do

! Stop or continue

  write(*,*)
  if (choice == 'n') stop

end subroutine ask_stop

!-----------------------------------------------------------------------------
! Checks surface x,y for violations of curvature contraints 
!     reversals > max_curv_reverse
!     highlows  > max_curv_highlow
! 
! and handles user response  
!-----------------------------------------------------------------------------

subroutine  check_handle_curve_violations (info, x, y, max_curv_reverse, max_curv_highlow)

  use vardef,             only : curv_threshold, highlow_threshold
  use os_util,            only : print_warning
  use airfoil_operations, only : show_reversals_highlows, get_curv_violations


  character(*),                   intent(in) :: info
  double precision, dimension(:), intent(in) :: x, y
  integer,                        intent(in) :: max_curv_reverse, max_curv_highlow

  integer :: n, max, nreverse_violations, nhighlow_violations

  call get_curv_violations (x, y, & 
                            curv_threshold, highlow_threshold, & 
                            max_curv_reverse, max_curv_highlow,   &
                            nreverse_violations, nhighlow_violations)

  ! Exit if everything is ok 
  if ((nreverse_violations + nhighlow_violations) == 0) return 

  call print_warning ("Curvature violations on " // trim(info))
  write (*,*)

  if (nreverse_violations > 0) then 
    n   = nreverse_violations + max_curv_reverse
    max = max_curv_reverse
    write (*,'(11x,A,I2,A,I2)')"Found ",n, " Reversal(s) where max_curv_reverse is set to ", max
  end if 

  if (nhighlow_violations > 0) then 
    n   = nhighlow_violations + max_curv_highlow
    max = max_curv_highlow
    write (*,'(11x,A,I2,A,I2)')"Found ",n, " HighLow(s) where max_curv_highlow is set to ", max
  end if 

  write (*,*)
  call show_reversals_highlows ('', x, y, curv_threshold, highlow_threshold )
  write (*,*)
  write (*,'(11x,A)') 'The Optimizer may not found a solution with this inital violation.'
  write (*,'(11x,A)') 'Either increase max_curv_reverse or curv_threshold (not recommended) or'
  write (*,'(11x,A)') 'choose another seed airfoil. Find details in geometry plot of the viszualizer.'
  call ask_stop('')

end subroutine check_handle_curve_violations



end module input_sanity
