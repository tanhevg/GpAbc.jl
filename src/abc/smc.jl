#
# Returns a 2D array of distributions. The ij-th element is for the
# j-th element of the i-th particle from the previous population
#
function generate_kernels(
        population::AbstractArray{F,2},
        priors::AbstractArray{D,1},
        ) where {
        F<:AbstractFloat,
        D<:ContinuousUnivariateDistribution,
        }
    n_particles = size(population, 1)
    n_params = size(population, 2)

    if n_particles > 1
        stds = std(population, 1)[:]
    else
        stds = 1e-3 * ones(n_params) # If there is only one particle we cannot compute the sd - use a small value instead?
    end

    lowers = minimum.(priors)
    uppers = maximum.(priors)

    CUD = ContinuousUnivariateDistribution
    kernels = Matrix{CUD}(n_particles, n_params)
    for j in 1:n_params
        means = population[:, j]
        kernels[:, j] = TruncatedNormal.(means, stds[j]*sqrt(2.0), lowers[j], uppers[j])
    end

    return kernels
end


function generate_parameters(
        batch_size::Int64,
        priors::AbstractArray{D1,1},
        old_weights::StatsBase.Weights,
        kernels::AbstractArray{D2,2},
        ) where {
        D1, D2<:ContinuousUnivariateDistribution
        }

    n_params = length(priors)

    # ADD DimensionMismatch THROWS SO @inbounds CAN BE USED?

    # the kernels must be centered around the old particles
    # and truncated to the priors.

    particles = StatsBase.sample(indices(kernels, 1), old_weights, batch_size)
    # println("particle: $particles")
    perturbed_parameters = rand.(kernels[particles,:])
    # println("perturbed_parameters = $perturbed_parameters")

    # gives a batch_size x n_params matrix of prior pdfs in perturbed parameters
    pdfs = pdf.(reshape(priors, 1, n_params), perturbed_parameters)
    numerators = prod(pdfs, 2) # multiply across rows, to get a column vector of products of size batch_size

    denominators = zeros(length(numerators), 1)
    for k in eachindex(denominators)
        denominator_pdfs = pdf.(kernels, reshape(perturbed_parameters[k, :], 1, n_params))
        denominator_summands = prod(denominator_pdfs, 2)
        denominators[k] = sum(old_weights .* denominator_summands)
    end

    weight = numerators ./ denominators

    return perturbed_parameters, weight
end

# function generate_parameters_no_weights(
#         n_batch_size::Int64,
#         old_parameters::AbstractArray{F,2},
#         old_weights::StatsBase.Weights,
#         kernels::AbstractArray{D2,2}
#         ) where {
#         D2<:ContinuousUnivariateDistribution,
#         F<:AbstractFloat,
#         }
#     particles = StatsBase.sample(indices(old_parameters, 1), old_weights, n_batch_size)
#     return rand.(kernels[particles,:])
# end

function normalise(
        weights::StatsBase.AbstractWeights;
        tosum = 1.0,
        )
    WeightType = typeof(weights)
    weights = WeightType(weights.values .* (tosum / sum(weights.values)), tosum)

    return weights
end

function normalise(weight_values::AbstractArray{F, 1}, tosum = 1.0) where F<:AbstractFloat
    return StatsBase.Weights(weight_values .* (sum(weight_values) / tosum), tosum)
end

#
# Initialise a simulated ABC-SMC run
#
function initialiseABCSMC(input::SimulatedABCSMCInput,
        reference_data::AbstractArray{Float64,2};
        write_progress = true,
        progress_every = 1000,
        )
    # construct summary statistic function to be used in all runs
    built_summary_statistic = build_summary_statistic(input.summary_statistic)

    # the first run is an ABC rejection simulation
    rejection_input = SimulatedABCRejectionInput(input.n_params,
                                        input.n_particles,
                                        input.threshold_schedule[1],
                                        input.priors,
                                        built_summary_statistic,
                                        input.distance_function,
                                        input.simulator_function,
                                        input.max_iter,
                                        )

    rejection_output = ABCrejection(rejection_input,
                                    reference_data;
                                    write_progress = write_progress,
                                    progress_every = progress_every,
                                    )

    tracker =  SimulatedABCSMCTracker(input.n_params,
                             [rejection_output.n_accepted],
                             [rejection_output.n_tries],
                             [rejection_output.threshold],
                             [rejection_output.population],
                             [rejection_output.distances],
                             [rejection_output.weights],
                             input.priors,
                             built_summary_statistic,
                             built_summary_statistic(reference_data),
                             input.distance_function,
                             input.simulator_function,
                             input.max_iter
                             )

    return tracker
end

#
# Initialise an emulated ABC-SMC run
#
function initialiseABCSMC(input::EmulatedABCSMCInput,
        reference_data::AbstractArray{Float64,2};
        write_progress = true)

    # the first run is an ABC rejection simulation
    rejection_input = EmulatedABCRejectionInput(input.n_params,
                                        input.n_particles,
                                        input.threshold_schedule[1],
                                        input.priors,
                                        input.batch_size,
                                        input.max_iter,
                                        input.train_emulator_function)

    rejection_output = ABCrejection(rejection_input,
                                    reference_data;
                                    write_progress = write_progress)

    tracker = EmulatedABCSMCTracker(input.n_params,
                             [rejection_output.n_accepted],
                             [rejection_output.n_tries],
                             [rejection_output.threshold],
                             [rejection_output.population],
                             [rejection_output.distances],
                             [rejection_output.weights],
                             input.priors,
                             input.train_emulator_function,
                             input.batch_size,
                             input.max_iter,
                             [rejection_output.emulator] # emulators
                             )

    return tracker
end

#
# Iterate a simulated ABC-SMC
#
function iterateABCSMC!(tracker::SimulatedABCSMCTracker,
        threshold::AbstractFloat,
        n_toaccept::Integer,
        reference_data::AbstractArray{Float64,2};
        write_progress = true,
        progress_every = 1000)

    if write_progress
        info(string(DateTime(now())), " ϵ = $threshold.", prefix="GpABC SMC Simulation ")
    end
    if threshold > tracker.threshold_schedule[end]
        warn("current threshold less strict than previous one.")
    end

    # initialise
    n_tries = 0
    n_accepted = 0
    kernels, population, distances, weight_values = initialise_abcsmc_iteration(tracker, n_toaccept)

    parameters = zeros(input.n_params)
    distance = 0.0
    weight_value = 0.0

    # simulate
    while n_accepted < n_toaccept && n_tries < tracker.max_iter

        # run simulation for a single particle
        try
            parameters, distance, weight_value = check_particle(tracker, kernels)
        catch e
            if isa(e, DimensionMismatch)
                # This prevents the whole code from failing if there is a problem
                # solving the differential equation(s). The exception is thrown by the 
                # distance function
                warn("The summarised simulated data does not have the same size as the summarised reference data. If this is not happening at every iteration it may be due to the behaviour of DifferentialEquations::solve - please check for related warnings. Continuing to the next iteration.")
                n_tries += 1
                continue
            else
                throw(e)
            end
        end

        n_tries += 1

        # Handle result
        if distance <= threshold
            n_accepted += 1
            population[n_accepted,:] = parameters
            distances[n_accepted] = distance
            weight_values[n_accepted] = weight_value
        end

        if write_progress && (n_tries % progress_every == 0)
            info(string(DateTime(now())), " Accepted $(n_accepted)/$(n_tries) particles.", prefix="GpABC SMC Simulation ")
        end
    end

    if n_accepted == 0
        warn("Simulation reached maximum $(tracker.max_iter) iterations without selecting any particles")
        return false
    end

    if n_accepted < n_toaccept
        population = population[1:n_accepted, :]
        weight_values = weight_values[1:n_accepted]
        distances = distances[1:n_accepted]
        warn("Simulation reached maximum $(tracker.max_iter) iterations before finding $(n_toaccept) particles - will return $n_accepted")
    else
        info(string(DateTime(now())), " Finished. Accepted $(n_accepted)/$(n_toaccept).", prefix="GpABC SMC Simulation ")
    end

    update_smctracker!(tracker, n_accepted, n_tries, threshold,
                        population, distances, weight_values)

    return true
end

#
# Iterate a emulated ABC-SMC
#
function iterateABCSMC!(tracker::EmulatedABCSMCTracker,
        threshold::AbstractFloat,
        n_toaccept::Integer,
        reference_data::AbstractArray{Float64,2};
        write_progress = true,
        progress_every = 1000
        )
    if write_progress && !for_model_selection
        info(string(DateTime(now())), " ϵ = $threshold.", prefix="GpABC SMC Emulation ")
    end

    if threshold > tracker.threshold_schedule[end]
        println("Warning: current threshold less strict than previous one.")
    end

    # retrain emulator using perturbed particles from the previous population
    emulator = retrain_emulator(tracker)

    # initialise
    iter_no = 0
    n_accepted = 0
    n_tries = 0
    kernels, population, all_distances, all_weight_values = initialise_abcsmc_iteration(tracker, n_toaccept)

    # emulate
    while n_accepted < n_toaccept && iter_no < tracker.max_iter

        parameters, distances, vars, weight_values = check_particle_batch(tracker, kernels, emulator)
        n_tries += length(distances)
        accepted_indices = find((distances .<= threshold) .& (sqrt.(vars) .<= threshold)) # todo more variance controls
        # accepted_indices = find(distances .<= threshold)
        n_include = length(accepted_indices)
        if n_accepted + n_include > n_toaccept
            n_include = n_toaccept - n_accepted
            accepted_indices = accepted_indices[1:n_include]
        end
        distances = distances[accepted_indices]
        weight_values = weight_values[accepted_indices]
        parameters = parameters[accepted_indices, :]
        store_slice = n_accepted + 1 : n_accepted + n_include
        n_accepted += n_include
        population[store_slice,:] = parameters
        all_distances[store_slice] = distances
        all_weight_values[store_slice] = weight_values

        if write_progress
            info(string(DateTime(now())), " Accepted $(n_accepted)/$(n_tries) particles.", prefix="GpABC SMC Emulation ")
        end

        iter_no += 1

    end

    if n_accepted == 0
        warn("Emulation reached maximum $(tracker.max_iter) iterations without selecting any particles")
        return false
    end

    if n_accepted < n_toaccept
        population = population[1:n_accepted, :]
        all_weight_values = all_weight_values[1:n_accepted]
        all_distances = all_distances[1:n_accepted]
        warn("Emulation reached maximum $(tracker.max_iter) iterations before finding $(n_toaccept) particles - will return $n_accepted")
    end

    update_smctracker!(tracker, n_accepted, n_tries, threshold,
                        population, all_distances, all_weight_values, emulator)

    return true
end

function buildAbcSmcOutput(tracker::EmulatedABCSMCTracker)
    EmulatedABCSMCOutput(length(tracker.priors),
                        tracker.n_accepted,
                        tracker.n_tries,
                        tracker.threshold_schedule,
                        tracker.population,
                        tracker.distances,
                        tracker.weights,
                        tracker.emulators)
end

function buildAbcSmcOutput(tracker::SimulatedABCSMCTracker)
    SimulatedABCSMCOutput(length(tracker.priors),
                        tracker.n_accepted,
                        tracker.n_tries,
                        tracker.threshold_schedule,
                        tracker.population,
                        tracker.distances,
                        tracker.weights)
end

"""
  ABCSMC

Run a ABC-SMC computation using either simulation (the model is simulated in full for each parameter vector from which the corresponding
distance to observed data is used to construct the posterior) or emulation (a regression model trained to predict the distance from the
parameter vector directly is used to construct the posterior). Whether simulation or emulation is used is controlled by the type of `input`.

# Arguments
- `input::ABCSMCInput`: An ['SimulatedABCSMCInput'](@ref) or ['EmulatedABCSMCInput'](@ref) object that defines the settings for the ABC-SMC run.
- `reference_data::AbstractArray{Float64,2}`: The observed data to which the simulated model output will be compared. Size: (n_model_trajectories, n_time_points)
- `write_progress::Bool`: Optional argument controlling whether progress is written to `out_stream`.
- `progress_every::Int`: Progress will be written to `out_stream` every `progress_every` simulations (optional, ignored if `write_progress` is `False`).

# Return
An object that inherits from ['ABCSMCOutput'](@ref), depending on whether a `input` is a ['SimulatedABCSMCInput'](@ref) or ['EmulatedABCSMCInput'](@ref).
"""
function ABCSMC(
        input::ABCSMCInput,
        reference_data::AbstractArray{Float64,2};
        write_progress = true,
        progress_every = 1000,
        )
    n_toaccept = input.n_particles

    tracker = initialiseABCSMC(input,
                               reference_data;
                               write_progress = write_progress)

    if tracker.n_accepted[1] > 0
        for i in 2:length(input.threshold_schedule)
            # @assert size(tracker.population[end], 1) > 0 "No particles were accepted by step #$(i-1) of ABC SMC"
            threshold = input.threshold_schedule[i]
            complete_threshold = iterateABCSMC!(tracker,
                           threshold,
                           input.n_particles,
                           reference_data;
                           write_progress = write_progress,
                           progress_every = progress_every,
                           )
            if !complete_threshold
                break
            end
        end
    else
        warn("No particles selected at initial rejection ABC step of SMC ABC")
    end

    return buildAbcSmcOutput(tracker)
end

# not exported
function initialise_abcsmc_iteration(tracker::ABCSMCTracker, n_toaccept::Integer)

    kernels = generate_kernels(tracker.population[end], tracker.priors)
    population = zeros(n_toaccept, tracker.n_params)
    distances = zeros(n_toaccept)
    weight_values = zeros(n_toaccept)

    return kernels, population, distances, weight_values
end

# not exported
# TODO: better function name?
function check_particle(
    tracker::SimulatedABCSMCTracker,
    kernels::Matrix{CUD}) where {
    CUD <: ContinuousUnivariateDistribution
    }

    parameters, weight_value = generate_parameters(1, tracker.priors, tracker.weights[end], kernels)
    parameters = parameters[1, :]
    weight_value = weight_value[1]
    simulated_data = tracker.simulator_function(parameters)
    summarised_simulated_data = tracker.summary_statistic(simulated_data)
    distance = tracker.distance_function(tracker.summarised_reference_data, summarised_simulated_data)

    return parameters, distance, weight_value
end

function check_particle_batch(
    tracker::EmulatedABCSMCTracker,
    kernels::Matrix{CUD},
    emulator) where {
    CUD <: ContinuousUnivariateDistribution
    }

    parameters, weight_values = generate_parameters(tracker.batch_size,
                                             tracker.priors,
                                             tracker.weights[end],
                                             kernels)

    distances, vars = gp_regression(parameters, emulator)
    return parameters, distances, vars, weight_values
end

# not exported
function update_smctracker!(tracker::SimulatedABCSMCTracker, n_accepted::Integer,
    n_tries::Integer, threshold::AbstractFloat, population::AbstractArray{Float64,2},
    distances::AbstractArray{Float64,1}, weight_values::AbstractArray{Float64,1})

    push!(tracker.n_accepted, n_accepted)
    push!(tracker.n_tries, n_tries)
    push!(tracker.threshold_schedule, threshold)
    push!(tracker.population, population)
    push!(tracker.distances, distances)
    # Do not want to normalise weights now if doing model selection - will do at
    # end of population at model selection level
    push!(tracker.weights, normalise(weight_values))
end

# not exported
function update_smctracker!(tracker::EmulatedABCSMCTracker, n_accepted::Integer,
    n_tries::Integer, threshold::AbstractFloat, population::AbstractArray{Float64,2},
    distances::AbstractArray{Float64,1}, weight_values::AbstractArray{Float64,1},
    emulator)

    push!(tracker.n_accepted, n_accepted)
    push!(tracker.n_tries, n_tries)
    push!(tracker.threshold_schedule, threshold)
    push!(tracker.population, population)
    push!(tracker.distances, distances)
    # Do not want to normalise weights now if doing model selection - will do at
    # end of population at model selection level
    push!(tracker.weights, normalise(weight_values))
    push!(tracker.emulators, emulator)
end

function retrain_emulator(tracker::EmulatedABCSMCTracker)

    # prior_sampling_function(n_design_points) = generate_parameters_no_weights(n_design_points,
    #     old_population,
    #     old_weights,
    #     kernels)

    prior_sampling_function = function(n_design_points)
        ret_idx = StatsBase.sample(indices(tracker.population[end], 1), tracker.weights[end], n_design_points)
        return tracker.population[end][ret_idx, :]
    end
    emulator = tracker.train_emulator_function(prior_sampling_function)

    return emulator
end
