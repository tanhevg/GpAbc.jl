using KernelDensity
using PyPlot
using PyCall
@pyimport matplotlib.patches as patches
@pyimport matplotlib.legend_handler as lh
@pyimport matplotlib.lines as lines


function scale_outer_intervals(intervals, scale=1.0)
    int_min = min([int[1] for int in intervals]...)
    int_max = max([int[2] for int in intervals]...)
    int_scaled_half = (int_max - int_min) * scale / 2.0
    int_mid = (int_min + int_max) / 2.0
    int_mid - int_scaled_half, int_mid + int_scaled_half
end

# This script relies on data (emu_out, sim_out) that is generated by running smc-abc-script.jl
function plot_emulation_vs_simulation(emu_out, sim_out)
            grid_size = emu_out.n_params
            emu_handle = nothing
            sim_handle = nothing
            kernel_bandwidth_scale = 0.09
            bounds_scale = 1.2
            # population_colors = ["#B1E9DE", "#007731"]
            population_colors = ["#DDF4F7", "#B1E9DE", "#63D3BB", "#00BD8B", "#007731"]

            contour_colors = ["white", "#FFE9EC", "#FFBBC5", "#FF8B9C", "#FF5D75", "#FF2F4E", "#D0001F", "#A20018", "#990017", "#800013"]
            simulation_color = "#08519c"
            emulation_color = "#ff6600"
            sim_count = 30
            h_sim_joint = nothing
            h_emu_pops = nothing
            h_sim_marg = nothing
            h_emu_marg = nothing
            h_true = nothing
            for i in 1:grid_size
                for j in 1:grid_size
                    subplot2grid((grid_size, grid_size), (i - 1, j - 1))
                    if j < i
                        x_data_emu = emu_out.population[end][:,j]
                        y_data_emu = emu_out.population[end][:,i]
                        x_data_sim = sim_out.population[end][:,j]
                        y_data_sim = sim_out.population[end][:,i]
                        sim_size = size(sim_out.population[end], 1)
                        if sim_size > sim_count
                            idx = randperm(sim_size)[1:sim_count]
                            x_data_sim = x_data_sim[idx]
                            y_data_sim = y_data_sim[idx]
                        end
                        x_extr_emu = extrema(x_data_emu)
                        y_extr_emu = extrema(y_data_emu)
                        x_extr_sim = extrema(x_data_sim)
                        y_extr_sim = extrema(y_data_sim)

                        xlim(scale_outer_intervals([x_extr_emu, x_extr_sim], bounds_scale))
                        ylim(scale_outer_intervals([y_extr_emu, y_extr_sim], bounds_scale))

                        bandwidth = (-kernel_bandwidth_scale * -(x_extr_emu...), -kernel_bandwidth_scale * -(y_extr_emu...))
                        kde_joint = kde((x_data_emu, y_data_emu), bandwidth=bandwidth)
                        contour_x = linspace(scale_outer_intervals([x_extr_emu], bounds_scale)..., 100)
                        contour_y = linspace(scale_outer_intervals([y_extr_emu], bounds_scale)..., 100)
                        contour_z = pdf(kde_joint, contour_x, contour_y)
                        contourf(contour_x, contour_y, contour_z, 8, colors=contour_colors, zorder=1)

                        h_sim_joint = scatter(x_data_sim, y_data_sim, marker="x", color=simulation_color, zorder=2)
                        true_param_x = true_params[param_indices[j]]
                        true_param_y = true_params[param_indices[i]]
                        plot([true_param_x, true_param_x], [0, true_param_y], color=:black, linestyle=:dashed, linewidth=0.5)
                        plot([0, true_param_x], [true_param_y, true_param_y], color=:black, linestyle=:dashed, linewidth=0.5)
                    elseif j > i
                        h_emu_pops = []
                        for iter_idx in 1:length(emu_out.population)
                            h_emu_pop = scatter(emu_out.population[iter_idx][:,j], emu_out.population[iter_idx][:,i],
                                color=population_colors[iter_idx], zorder=iter_idx, marker=".")
                            push!(h_emu_pops, h_emu_pop)
                        end
                        xlims = scale_outer_intervals([extrema(pop[:, j]) for pop in emu_out.population])
                        xlim(xlims)
                        ylims = scale_outer_intervals([extrema(pop[:, i]) for pop in emu_out.population])
                        ylim(ylims)
                        true_param_x = true_params[param_indices[j]]
                        true_param_y = true_params[param_indices[i]]
                        plot([true_param_x, true_param_x], [ylims[1], true_param_y], color=:black, linestyle=:dashed, linewidth=0.5, zorder=length(emu_out.population)+1)
                        plot([xlims[1], true_param_x], [true_param_y, true_param_y], color=:black, linestyle=:dashed, linewidth=0.5, zorder=length(emu_out.population)+1)
                    else#if i == j
                        emu_data = emu_out.population[end][:,i]
                        sim_data = sim_out.population[end][:,i]
                        extr_emu = extrema(emu_data)
                        extr_sim = extrema(sim_data)
                        kde_emu = kde(emu_data, bandwidth=-kernel_bandwidth_scale * -(extr_emu...))
                        kde_sim = kde(sim_data, bandwidth=-kernel_bandwidth_scale * -(extr_sim...))
                        x_bounds = scale_outer_intervals([extr_emu, extr_sim], bounds_scale)
                        xlim(x_bounds)
                        x_plot = linspace(x_bounds..., 100)
                        y_emu_plot = pdf(kde_emu,x_plot)
                        y_sim_plot = pdf(kde_sim,x_plot)
                        h_emu_marg = plot(x_plot, y_emu_plot, color=emulation_color)
                        h_sim_marg = plot(x_plot, y_sim_plot, color=simulation_color)
                        yticks([])
                        true_param = true_params[param_indices[i]]
                        max_pdf = max(pdf(kde_emu, true_param), pdf(kde_sim, true_param))
                        h_true = plot([true_param, true_param], [0, max_pdf], color=:black, linestyle=:dashed, linewidth=0.5)
                    end
                end
            end
            # https://matplotlib.org/gallery/text_labels_and_annotations/legend_demo.html
            h_emu_pops = Tuple(h_emu_pops[max(1, length(h_emu_pops)-3):end])
            h_emu = (h_emu_marg[1],
                lines.Line2D([], [], linestyle="None", marker="s", color=contour_colors[7],
                markerfacecoloralt=contour_colors[5], fillstyle="right", markeredgewidth=0.0))
            h_sim = (h_sim_marg[1], h_sim_joint)
            figlegend([h_sim; h_emu_pops; h_emu; h_true],
                ["Simulation result", "Emulated populations", "Emulation result", "True value"],
                ncol=2, loc="lower center",
                handler_map=Dict(h_sim=>lh.HandlerTuple(ndivide=nothing),
                        h_emu_pops=>lh.HandlerTuple(ndivide=nothing),
                        h_emu=>lh.HandlerTuple(ndivide=nothing))
            )
end

sim_truncate = 4
sim_out1 = GpABC.SimulatedABCSMCOutput(sim_out.n_params, sim_out.n_accepted[1:sim_truncate],
                        sim_out.n_tries[1:sim_truncate], sim_out.threshold_schedule[1:sim_truncate],
                        sim_out.population[1:sim_truncate], sim_out.distances[1:sim_truncate],
                        sim_out.weights[1:sim_truncate])

emu_truncate = 4
emu_out1 = GpABC.EmulatedABCSMCOutput(emu_out.n_params, emu_out.n_accepted[1:emu_truncate],
                        emu_out.n_tries[1:emu_truncate], emu_out.threshold_schedule[1:emu_truncate],
                        emu_out.population[1:emu_truncate], emu_out.distances[1:emu_truncate],
                        emu_out.weights[1:emu_truncate], emu_out.emulators[1:emu_truncate])
ion()
fig = figure()
ioff()
plot_emulation_vs_simulation(emu_out, sim_out)
subplots_adjust(
left    =  0.08,
bottom  =  0.2,
right   =  0.96,
top     =  0.97,
wspace  =  0.35,
hspace  =  0.26)
show(fig)

# savefig("/project/home17/et517/Dropbox/GaussianProcesses/Bioinformatics paper/fig-1b-res-3-gene-3-param-noise.eps")
