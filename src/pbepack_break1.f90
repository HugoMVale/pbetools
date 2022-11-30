module pbepack_break1
!! This module implements derived types and procedures to compute the breakage term
!! for 1D PBEs.
   use pbepack_kinds
   use pbepack_basetypes, only: particleterm
   use hrweno_grids, only: grid1
   implicit none
   private

   public :: breakterm

   type, extends(particleterm) :: breakterm
   !! Breakage term class.
      procedure(bfnc1_t), nopass, pointer :: bfnc => null()
         !! breakage frequency function
      procedure(dfnc1_t), nopass, pointer :: dfnc => null()
         !! daughter distribution function
      real(rk), allocatable :: b(:)
         !! vector of breakage frequencies
      real(rk), allocatable :: d(:)
         !! vector of daughter probabilities
      logical :: update_b = .true.
         !! flag to select if matrix 'b' should be updated at each step.
      logical :: empty_b = .true.
         !! flag indicating state of matrix 'b'.
      logical :: update_d = .true.
         !! flag to select if matrix 'd' should be updated at each step.
      logical :: empty_d = .true.
         !! flag indicating state of matrix 'd'.
   contains
      procedure, pass(self) :: eval => breakterm_eval
      procedure, pass(self), private :: breakterm_allocations
      procedure, pass(self), private :: compute_b
      procedure, pass(self), private :: compute_d
   end type breakterm

   abstract interface
      pure real(rk) function bfnc1_t(x, y)
      !! Breakage frequency for 1D system
         import :: rk
         real(rk), intent(in) :: x
            !! internal coordinate of particle
         real(rk), intent(in) :: y(:)
            !! environment vector
      end function

      pure real(rk) function dfnc1_t(xd, xo, y)
      !! Daughter distribution for 1D system
         import :: rk
         real(rk), intent(in) :: xd
            !! internal coordinate of daughter particle
         real(rk), intent(in) :: xo
            !! internal coordinate of original particle
         real(rk), intent(in) :: y(:)
            !! environment vector
      end function
   end interface

   interface breakterm
      module procedure :: breakterm_init
   end interface breakterm

contains

   type(breakterm) function breakterm_init(bfnc, dfnc, moment, grid, update_b, update_d, &
                                           name) result(self)
   !! Initialize 'breakterm' object.
      procedure(bfnc1_t) :: bfnc
         !! breakage frequency function, \( b(x,y) \)
      procedure(dfnc1_t) :: dfnc
         !! daughter distribution function, \( d(x,x',y) \)
      integer, intent(in) :: moment
         !! moment of 'x' to be conserved upon breakage (>0)
      type(grid1), intent(in), target, optional :: grid
         !! grid1 object
      logical, intent(in), optional :: update_b
         !! flag to select if matrix 'b' should be updated at each step
      logical, intent(in), optional :: update_d
         !! flag to select if matrix 'd' should be updated at each step
      character(*), intent(in), optional :: name
         !! object name

      self%bfnc => bfnc
      self%dfnc => dfnc
      call self%set_moment(moment)
      call self%set_name(name)
      if (present(update_b)) self%update_b = update_b
      if (present(update_d)) self%update_d = update_d

      if (present(grid)) then
         call self%set_grid(grid)
         call self%breakterm_allocations()
         self%inited = .true.
         self%msg = "Initialization completed successfully"
      else
         self%msg = "Missing 'grid'."
      end if

   end function breakterm_init

   pure subroutine breakterm_allocations(self)
   !! Allocator arrays 'breakterm' class.
      class(breakterm), intent(inout) :: self
         !! object

      ! Call parent method
      call self%particleterm_allocations()

      ! Do own allocations
      if (associated(self%grid)) then
         associate (nc => self%grid%ncells)
            allocate (self%b(nc), self%d((nc - 2)*(nc - 1)/2 + 3*(nc - 1)))
         end associate
      else
         call self%error_msg("Allocation failed due to missing grid.")
      end if

   end subroutine breakterm_allocations

   pure subroutine breakterm_eval(self, np, y, result, birth, death)
   !! Evaluate the rate of breakage at a given instant, using the technique described in
   !! Section 3.3 of Kumar and Ramkrishna (1996). The birth/source term is computed according
   !! to a slightly different procedure: the summation is done from the perspective of the
   !! original particles (the ones that break up), which allows for a simpler and more
   !! efficient calculation of the particle split fractions.
      class(breakterm), intent(inout) :: self
         !! object
      real(rk), intent(in) :: np(:)
         !! vector(ncells) with number of particles in cell 'i'
      real(rk), intent(in) :: y(:)
         !! environment vector
      real(rk), intent(out), optional :: result(:)
         !! vector(ncells) with net rate of change (birth-death)
      real(rk), intent(out), optional :: birth(:)
         !! vector(ncells) with birth term
      real(rk), intent(out), optional :: death(:)
         !! vector(ncells) with death term

      real(rk) :: weight(2)
      integer :: i, k

      associate (nc => self%grid%ncells, b => self%b, &
                 birth_ => self%birth, death_ => self%death, result_ => self%result)

         ! Evaluate breakage frequency and daughter distribution kernels
         if (self%update_b .or. self%empty_b) call self%compute_b(y)
         !if (self%update_d .or. self%empty_d) call self%compute_d(y)

         ! Death/sink term
         death_ = b*np
         if (present(death)) death = death_

         ! Birth/source term
         birth_ = ZERO
         do k = 2, nc
            do i = 1, k - 1
               weight = daughter_split(i, k)
               birth_(i) = birth_(i) + weight(1)*death_(k)
               birth_(i + 1) = birth_(i + 1) + weight(2)*death_(k)
            end do
         end do
         if (present(birth)) birth = birth_

         ! Net rate
         result_ = birth_ - death_
         if (present(result)) result = result_

      end associate

   contains

      pure function daughter_split(i_, k_) result(res)
      !! Evaluate the fraction of cell k assigned to cells i and (i+1).
      !! Based on Equation 27, but improved to consider the contribution to cell 1 arising
      !! from the integral between the left boundary of the grid domain and the center of cell
      !! 1. For this small region, we can only chose to preserve number or mass (not both). The
      !! current algorithm implements mass conservation.
         integer, intent(in) :: i_, k_
         real(rk) :: res(2)
         real(rk) :: d0, dm

         associate (x => self%grid%center, xo => self%grid%center(k_), m => self%moment)
            d0 = dfnc_integral(x(i_), x(i_ + 1), xo, 0)
            dm = dfnc_integral(x(i_), x(i_ + 1), xo, m)
            res(1) = (d0*x(i_ + 1)**m - dm)/(x(i_ + 1)**m - x(i_)**m)
            res(2) = d0 - res(1)
            if (i_ == 1) then
               !res(1) = res(1) + dfnc_integral(self%grid%left(1), x(1), xo, 0)
               res(1) = res(1) + dfnc_integral(self%grid%left(1), x(1), xo, m)/x(1)**m
            end if
         end associate

      end function daughter_split

      pure real(rk) function dfnc_integral(xa, xb, xo, m_) result(res)
      !! Numerical approximation to \( \int_{x_a}^{x_b} x^m dfnc(x,x_o,y)dx \) using Simpson's
      !! rule (with trapezoidal rule, the mass balance drops to 1e-3).
      !! Equation 28.
         real(rk), intent(in) :: xa, xb, xo
         integer, intent(in) :: m_

         real(rk) :: xc
         xc = (xa + xb)/2
         res = ( &
               xa**m_*self%dfnc(xa, xo, y) + &
               xb**m_*self%dfnc(xb, xo, y) + &
               xc**m_*self%dfnc(xc, xo, y)*4 &
               )*(xb - xa)/6
      end function dfnc_integral

   end subroutine breakterm_eval

   pure subroutine compute_b(self, y)
   !! Compute/update vector of breakage frequencies.
      class(breakterm), intent(inout) :: self
         !! object
      real(rk), intent(in) :: y(:)
         !! environment vector

      integer :: i

      do concurrent(i=1:self%grid%ncells)
         self%b(i) = self%bfnc(self%grid%center(i), y)
      end do

      if (self%empty_b) self%empty_b = .false.

   end subroutine compute_b

   pure subroutine compute_d(self, y)
   !! Compute/update vector of daughter probabilities.
   !! The distribution \( d(x,x',y) \) is only defined for \( x \leq x' \), leading to a
   !! triangular array of values. To avoid using such a 'special' array, the data is flattened
   !! and packed into a vector.
   !! @note: not active. Need better concept, covering 'd' and weights.
      class(breakterm), intent(inout) :: self
         !! object
      real(rk), intent(in) :: y(:)
         !! environment vector

      real(rk) :: xa
      integer :: i, j, k

      associate (nc => self%grid%ncells, x => self%grid%center)
      do j = 2, nc
         do i = 0, j
            if (i == 0) then
               xa = self%grid%left(1)
            else
               xa = self%grid%center(i)
            end if
            k = (j - 2)*(j - 1)/2 + 2*(j - 2) + (i + 1)
            self%d(k) = self%dfnc(xa, x(j), y)
         end do
      end do
      end associate

      if (self%empty_d) self%empty_d = .false.

   end subroutine compute_d

end module pbepack_break1
